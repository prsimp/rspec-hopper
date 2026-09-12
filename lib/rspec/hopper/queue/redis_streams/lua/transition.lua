-- State transitions for in-flight units. One dispatcher, one function per mode.
--
-- KEYS: units, units:priority, attempts, meta, unit_state, workers
-- ARGV: mode, worker_id, ttl_ms, then mode-specific arguments (see dispatch).
--
-- Replies are arrays whose first element is a status string: "OK", "NONE",
-- "FINALIZED", "REQUEUED", "STALE" (fence failed) or "CORRUPT" (meta or the
-- unit's unit_state entry is missing after ready). STALE and CORRUPT are
-- status replies, not Lua errors, so the caller can tell them from Redis errors.

local units, priority, attempts, meta, unit_state, workers =
  KEYS[1], KEYS[2], KEYS[3], KEYS[4], KEYS[5], KEYS[6]
local mode, worker_id, ttl_ms = ARGV[1], ARGV[2], tonumber(ARGV[3])

local GROUP = "workers"
local STALE, CORRUPT = { "STALE" }, { "CORRUPT" }

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function now_ms()
  local t = redis.call("TIME")
  return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
end

local function stream_key(short)
  if short == "units" then
    return units
  elseif short == "units:priority" then
    return priority
  end
  error("unknown stream " .. tostring(short))
end

local function stream_short(key)
  if key == units then
    return "units"
  end
  return "units:priority"
end

-- Renews the inactivity TTL on every live key that exists. Never the lease or
-- the tombstone.
local function renew_ttls()
  for _, key in ipairs({ units, priority, attempts, meta, unit_state, workers }) do
    redis.call("PEXPIRE", key, ttl_ms)
  end
end

local function meta_present()
  return redis.call("EXISTS", meta) == 1
end

-- Pending-entry row for one entry: {id, consumer, idle_ms, delivery_count} or nil.
local function pending_row(stream, entry_id)
  local rows = redis.call("XPENDING", stream, GROUP, entry_id, entry_id, 1)
  local row = rows[1]
  if type(row) ~= "table" then
    return nil
  end
  return { id = row[1], consumer = row[2], idle_ms = tonumber(row[3]), delivery_count = tonumber(row[4]) }
end

-- The fence. Returns the pending row when the entry is still pending, owned
-- by worker_id and (when given) at the expected delivery count; nil otherwise.
local function fence(stream, entry_id, owner, delivery_count)
  local row = pending_row(stream, entry_id)
  if not row or row.consumer ~= owner then
    return nil
  end
  if delivery_count ~= nil and row.delivery_count ~= delivery_count then
    return nil
  end
  return row
end

-- Stream entry fields ({"id", "x", "type", "file"}) to a table.
local function entry_fields(list)
  local fields = {}
  for i = 1, #list, 2 do
    fields[list[i]] = list[i + 1]
  end
  return fields
end

local function read_unit_state(unit_id)
  local raw = redis.call("HGET", unit_state, unit_id)
  if not raw then
    return nil
  end
  return cjson.decode(raw)
end

local function write_unit_state(unit_id, state)
  redis.call("HSET", unit_state, unit_id, string.format(
    '{"retry_index":%d,"reclaim_count":%d,"entered_retry":%s}',
    state.retry_index, state.reclaim_count, tostring(state.entered_retry == true)
  ))
end

-- Encodes an ordered list of {key, value} (or {key, raw_json, true}) pairs as
-- one JSON object. Raw values are Ruby-encoded JSON embedded verbatim, never
-- re-encoded. Deterministic key order makes the log easy to read and diff.
local function json_object(pairs_list)
  local parts = {}
  for _, pair in ipairs(pairs_list) do
    local key, value, raw = pair[1], pair[2], pair[3]
    if value == nil then
      value = cjson.null
    end
    parts[#parts + 1] = cjson.encode(key) .. ":" .. (raw and value or cjson.encode(value))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function append_json(json)
  redis.call("XADD", attempts, "*", "json", json)
end

-- Appends a unit-scoped event. `extra` is an ordered list of pairs.
local function append_event(event_type, unit_id, state, extra)
  local pairs_list = {
    { "type", event_type },
    { "unit_id", unit_id },
    { "worker_id", worker_id },
    { "retry_index", state.retry_index },
    { "reclaim_count", state.reclaim_count },
    { "ownership_generation", 1 + state.retry_index + state.reclaim_count },
    { "at_ms", now_ms() },
  }
  for _, pair in ipairs(extra or {}) do
    pairs_list[#pairs_list + 1] = pair
  end
  append_json(json_object(pairs_list))
end

-- Stamps at_ms onto a Ruby-built event object without re-encoding it.
local function append_prebuilt(json)
  if json:sub(-1) ~= "}" then
    error("event payload is not a JSON object")
  end
  local body = json:sub(1, -2)
  local sep = (body:match("^%s*{%s*$") and "") or ","
  append_json(body .. sep .. '"at_ms":' .. now_ms() .. "}")
end

-- Merges `changes` into workers[worker_id]. Pass cjson.null to clear a field,
-- nil (absent) to leave it alone. `processed_delta` adds to the counter.
local function touch_worker(changes, processed_delta)
  local raw = redis.call("HGET", workers, worker_id)
  local record = raw and cjson.decode(raw) or { last_seen = 0, current_unit = cjson.null, processed = 0 }
  record.last_seen = now_ms()
  if changes.current_unit ~= nil then
    record.current_unit = changes.current_unit
  end
  record.processed = (tonumber(record.processed) or 0) + (processed_delta or 0)
  redis.call("HSET", workers, worker_id, json_object({
    { "last_seen", record.last_seen },
    { "current_unit", record.current_unit },
    { "processed", record.processed },
  }))
end

local function raw_or_null(json)
  if json == nil or json == "" then
    return { nil }
  end
  return { json, true }
end

local function nil_if_empty(value)
  if value == nil or value == "" then
    return nil
  end
  return value
end

-- Terminal transition shared by finalize, requeue (budget exhausted) and
-- reclaim (budget exhausted): XACK, finalized event, finalized_count += 1.
local function finalize_entry(stream, entry_id, unit_id, state, outcome, duration_ms, reason, errors_json, extra)
  redis.call("XACK", stream, GROUP, entry_id)
  local fields = {
    { "outcome", outcome },
    { "duration_ms", tonumber(duration_ms) or 0 },
    { "reason", nil_if_empty(reason) },
    { "errors", unpack(raw_or_null(errors_json)) },
    { "stream", stream_short(stream) },
    { "entry_id", entry_id },
  }
  for _, pair in ipairs(extra or {}) do
    fields[#fields + 1] = pair
  end
  append_event("finalized", unit_id, state, fields)
  redis.call("HINCRBY", meta, "finalized_count", 1)
end

-- Budget values are frozen into meta at initialization so every worker
-- enforces the same caps; the caller's own value is only a fallback.
local function budget(field, fallback)
  local value = redis.call("HGET", meta, field)
  return tonumber(value) or tonumber(fallback)
end

-- ---------------------------------------------------------------------------
-- Modes
-- ---------------------------------------------------------------------------

-- ARGV: stream, entry_id, unit_id. Fenced by consumer only; delivery count is
-- read from XPENDING and returned so the caller can build its handle.
local function delivery_accounting(short, entry_id, unit_id)
  local stream = stream_key(short)
  local row = fence(stream, entry_id, worker_id, nil)
  if not row then
    return STALE
  end
  local state = read_unit_state(unit_id)
  if not state then
    return CORRUPT
  end
  append_event("delivered", unit_id, state, {
    { "stream", short },
    { "entry_id", entry_id },
    { "delivery_count", row.delivery_count },
  })
  touch_worker({ current_unit = unit_id })
  renew_ttls()
  return { "OK", row.delivery_count, state.retry_index, state.reclaim_count }
end

-- First real entry in an XAUTOCLAIM reply. The reply is {next_id, entries} on
-- Redis 6.2 and {next_id, entries, deleted_ids} on 7+; on 6.2 `entries` may
-- hold false/nil placeholders for entries deleted from the stream. Only the
-- second element is ever inspected, so the shape does not matter.
local function first_claimed(reply)
  local entries = type(reply) == "table" and reply[2] or nil
  if type(entries) ~= "table" then
    return nil
  end
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and type(entry[2]) == "table" then
      return entry[1], entry_fields(entry[2])
    end
  end
  return nil
end

-- Oldest entry idle for at least timeout_ms, read before XAUTOCLAIM moves it
-- so the previous owner is still known.
local function idle_candidate(stream, timeout_ms)
  local rows = redis.call("XPENDING", stream, GROUP, "IDLE", timeout_ms, "-", "+", 1)
  local row = rows[1]
  if type(row) ~= "table" then
    return nil
  end
  return { id = row[1], consumer = row[2] }
end

local function unit_id_of(stream, entry_id)
  local range = redis.call("XRANGE", stream, entry_id, entry_id)
  local entry = range[1]
  if type(entry) ~= "table" then
    return nil
  end
  return entry_fields(entry[2]).id
end

-- Claims from one stream. Returns nil (nothing idle), CORRUPT, or the reply.
local function reclaim_from(stream, timeout_ms, max_reclaims)
  local candidate = idle_candidate(stream, timeout_ms)
  if candidate then
    -- Refuse before moving ownership when the unit's state is already gone.
    local candidate_unit = unit_id_of(stream, candidate.id)
    if candidate_unit and redis.call("HEXISTS", unit_state, candidate_unit) == 0 then
      return CORRUPT
    end
  end

  local reply = redis.call("XAUTOCLAIM", stream, GROUP, worker_id, timeout_ms, "0-0", "COUNT", 1)
  local entry_id, fields = first_claimed(reply)
  if not entry_id then
    return nil
  end

  local unit_id, unit_type = fields.id, fields.type
  local row = pending_row(stream, entry_id)
  local delivery_count = row and row.delivery_count or 0
  local previous_worker_id = (candidate and candidate.id == entry_id) and candidate.consumer or nil
  local state = read_unit_state(unit_id)
  if not state then
    return CORRUPT
  end

  if state.reclaim_count + 1 > max_reclaims then
    finalize_entry(stream, entry_id, unit_id, state, "failed", 0, "reclaim_budget_exhausted", nil, {
      { "previous_worker_id", previous_worker_id },
      { "delivery_count", delivery_count },
    })
    touch_worker({})
    renew_ttls()
    return { "FINALIZED", unit_id }
  end

  state.reclaim_count = state.reclaim_count + 1
  write_unit_state(unit_id, state)
  append_event("reclaimed", unit_id, state, {
    { "previous_worker_id", previous_worker_id },
    { "stream", stream_short(stream) },
    { "entry_id", entry_id },
    { "delivery_count", delivery_count },
  })
  touch_worker({ current_unit = unit_id })
  renew_ttls()
  return { "OK", stream_short(stream), entry_id, unit_id, unit_type, delivery_count, state.retry_index, state.reclaim_count }
end

-- ARGV: timeout_ms, max_reclaims. Priority stream first.
local function reclaim(timeout_ms, max_reclaims)
  timeout_ms = tonumber(timeout_ms)
  max_reclaims = budget("max_reclaims", max_reclaims)
  for _, stream in ipairs({ priority, units }) do
    local reply = reclaim_from(stream, timeout_ms, max_reclaims)
    if reply then
      return reply
    end
  end
  return { "NONE" }
end

-- ARGV: stream, entry_id, delivery_count, unit_id.
local function heartbeat(short, entry_id, delivery_count, unit_id)
  local stream = stream_key(short)
  if not fence(stream, entry_id, worker_id, tonumber(delivery_count)) then
    return STALE
  end
  redis.call("XCLAIM", stream, GROUP, worker_id, 0, entry_id, "JUSTID")
  touch_worker({ current_unit = unit_id })
  renew_ttls()
  return { "OK" }
end

-- ARGV: stream, entry_id, delivery_count, unit_id, outcome, duration_ms, reason, errors_json.
local function finalize(short, entry_id, delivery_count, unit_id, outcome, duration_ms, reason, errors_json)
  local stream = stream_key(short)
  if not fence(stream, entry_id, worker_id, tonumber(delivery_count)) then
    return STALE
  end
  local state = read_unit_state(unit_id)
  if not state then
    return CORRUPT
  end
  finalize_entry(stream, entry_id, unit_id, state, outcome, duration_ms, reason, errors_json)
  touch_worker({ current_unit = cjson.null }, 1)
  renew_ttls()
  return { "OK" }
end

local function max_requeued_units(tolerance)
  local total = tonumber(redis.call("HGET", meta, "total_units")) or 0
  -- Subtracting an epsilon keeps ceil(100 * 0.7) at 70, not 71.
  return math.max(0, math.ceil(total * tolerance - 1e-9))
end

-- ARGV: stream, entry_id, delivery_count, unit_id, unit_type, max_requeues,
--       requeue_tolerance, duration_ms, failure_summary, errors_json.
local function requeue(short, entry_id, delivery_count, unit_id, unit_type, max_requeues, tolerance, duration_ms,
                       failure_summary, errors_json)
  local stream = stream_key(short)
  if not fence(stream, entry_id, worker_id, tonumber(delivery_count)) then
    return STALE
  end
  local state = read_unit_state(unit_id)
  if not state then
    return CORRUPT
  end

  max_requeues = budget("max_requeues", max_requeues)
  tolerance = budget("requeue_tolerance", tolerance)
  local requeued_units = tonumber(redis.call("HGET", meta, "requeued_units_count")) or 0
  local over_unit_cap = state.retry_index + 1 > max_requeues
  local over_tolerance = (not state.entered_retry) and requeued_units >= max_requeued_units(tolerance)

  if over_unit_cap or over_tolerance then
    finalize_entry(stream, entry_id, unit_id, state, "failed", duration_ms, "retry_budget_exhausted", errors_json, {
      { "failure_summary", nil_if_empty(failure_summary) },
    })
    touch_worker({ current_unit = cjson.null }, 1)
    renew_ttls()
    return { "FINALIZED", state.retry_index }
  end

  if not state.entered_retry then
    state.entered_retry = true
    redis.call("HINCRBY", meta, "requeued_units_count", 1)
  end
  local previous_retry_index = state.retry_index
  state.retry_index = state.retry_index + 1
  write_unit_state(unit_id, state)
  redis.call("XACK", stream, GROUP, entry_id)
  local new_entry_id = redis.call("XADD", priority, "*", "id", unit_id, "type", unit_type)
  append_event("requeued", unit_id, state, {
    { "previous_retry_index", previous_retry_index },
    { "duration_ms", tonumber(duration_ms) or 0 },
    { "failure_summary", nil_if_empty(failure_summary) },
    { "errors", unpack(raw_or_null(errors_json)) },
    { "stream", short },
    { "entry_id", entry_id },
    { "new_entry_id", new_entry_id },
  })
  touch_worker({ current_unit = cjson.null }, 1)
  renew_ttls()
  return { "REQUEUED", state.retry_index }
end

-- ARGV: stream, entry_id, delivery_count, unit_id, elapsed_ms.
local function abandoned(short, entry_id, delivery_count, unit_id, elapsed_ms)
  local stream = stream_key(short)
  if not fence(stream, entry_id, worker_id, tonumber(delivery_count)) then
    return STALE
  end
  local state = read_unit_state(unit_id)
  if not state then
    return CORRUPT
  end
  append_event("abandoned", unit_id, state, {
    { "elapsed_ms", tonumber(elapsed_ms) or 0 },
    { "stream", short },
    { "entry_id", entry_id },
  })
  touch_worker({})
  renew_ttls()
  return { "OK" }
end

-- ARGV: current_unit (may be empty).
local function liveness(current_unit)
  touch_worker({ current_unit = nil_if_empty(current_unit) or cjson.null })
  renew_ttls()
  return { "OK" }
end

-- ARGV: Ruby-built event JSON. Not fenced, does not require meta.
local function append_prebuilt_event(json)
  append_prebuilt(json)
  renew_ttls()
  return { "OK" }
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

if mode == "worker_error" or mode == "stale_rejected" then
  return append_prebuilt_event(ARGV[4])
end

if not meta_present() then
  return CORRUPT
end

if mode == "delivery_accounting" then
  return delivery_accounting(ARGV[4], ARGV[5], ARGV[6])
elseif mode == "reclaim" then
  return reclaim(ARGV[4], ARGV[5])
elseif mode == "heartbeat" then
  return heartbeat(ARGV[4], ARGV[5], ARGV[6], ARGV[7])
elseif mode == "finalize" then
  return finalize(ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11])
elseif mode == "requeue" then
  return requeue(ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13])
elseif mode == "abandoned" then
  return abandoned(ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8])
elseif mode == "liveness" then
  return liveness(ARGV[4])
end
return redis.error_reply("ERR unknown transition mode " .. tostring(mode))
