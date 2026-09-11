-- Build initialization. Publishes the manifest exactly once per build id.
--
-- KEYS: units, units:priority, attempts, meta, unit_state, leader, exists
-- ARGV: mode ("success" | "failure"), lease token, ttl_ms, tombstone_ttl_ms,
--       JSON object of meta fields (string -> string),
--       JSON array of unit ids (success mode only),
--       unit type (optional, default "file")
--
-- Aborts with a Lua error (mapped by Ruby) when the caller no longer holds the
-- lease (LEASE_LOST), the tombstone exists (ALREADY_INITIALIZED) or meta is
-- already published (ALREADY_READY). Returns "ready" or "init_failed".

local units, priority, attempts, meta, unit_state, leader, exists =
  KEYS[1], KEYS[2], KEYS[3], KEYS[4], KEYS[5], KEYS[6], KEYS[7]
local mode, token = ARGV[1], ARGV[2]
local ttl_ms, tombstone_ttl_ms = tonumber(ARGV[3]), tonumber(ARGV[4])
local unit_type = ARGV[7] or "file"

local GROUP = "workers"
local INITIAL_UNIT_STATE = '{"retry_index":0,"reclaim_count":0,"entered_retry":false}'

local function now_ms()
  local t = redis.call("TIME")
  return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
end

local function fence()
  if redis.call("GET", leader) ~= token then
    return redis.error_reply("LEASE_LOST")
  end
  if redis.call("EXISTS", exists) == 1 then
    return redis.error_reply("ALREADY_INITIALIZED")
  end
  if redis.call("EXISTS", meta) == 1 then
    return redis.error_reply("ALREADY_READY")
  end
  return nil
end

local function write_meta(fields, extra)
  local args = {}
  for k, v in pairs(fields) do
    args[#args + 1] = k
    args[#args + 1] = tostring(v)
  end
  for k, v in pairs(extra) do
    args[#args + 1] = k
    args[#args + 1] = tostring(v)
  end
  redis.call("HSET", meta, unpack(args))
end

local function seed_units(unit_ids)
  redis.call("DEL", units, priority)
  redis.call("XGROUP", "CREATE", units, GROUP, "0", "MKSTREAM")
  redis.call("XGROUP", "CREATE", priority, GROUP, "0", "MKSTREAM")
  for _, id in ipairs(unit_ids) do
    redis.call("XADD", units, "*", "id", id, "type", unit_type)
    redis.call("HSET", unit_state, id, INITIAL_UNIT_STATE)
  end
end

local function set_ttls()
  redis.call("SET", exists, "1", "PX", tombstone_ttl_ms)
  for _, key in ipairs({ units, priority, attempts, meta, unit_state }) do
    redis.call("PEXPIRE", key, ttl_ms)
  end
end

local function init_success(fields, unit_ids)
  seed_units(unit_ids)
  write_meta(fields, { state = "ready", ready_at = now_ms(), finalized_count = 0, requeued_units_count = 0 })
  set_ttls()
  return "ready"
end

local function init_failure(fields)
  write_meta(fields, { state = "init_failed", ready_at = now_ms() })
  set_ttls()
  return "init_failed"
end

local aborted = fence()
if aborted then
  return aborted
end

local fields = cjson.decode(ARGV[5])
if mode == "success" then
  return init_success(fields, cjson.decode(ARGV[6]))
elseif mode == "failure" then
  return init_failure(fields)
end
return redis.error_reply("ERR unknown init mode " .. tostring(mode))
