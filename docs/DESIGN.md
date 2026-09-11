# rspec-hopper internal design contract

This document is the contract between the gem's layers. Every implementer works from
it; when it and the product spec (`../rspec-hopper-init.md`, not in this repo)
disagree, the product spec wins and this file must be corrected. Nothing in here is
user documentation; the README is written separately.

## Layout

```
lib/rspec/hopper.rb                        requires everything; before_fork/after_fork hook registry
lib/rspec/hopper/version.rb
lib/rspec/hopper/errors.rb                 error hierarchy and exit codes
lib/rspec/hopper/config.rb                 WorkConfig / ReportConfig (frozen Data)
lib/rspec/hopper/unit.rb                   Unit value object
lib/rspec/hopper/reservation.rb            Reservation handle value object
lib/rspec/hopper/keys.rb                   Redis key naming
lib/rspec/hopper/queue.rb                  Queue protocol (abstract) + result structs
lib/rspec/hopper/queue/redis_streams.rb    the one adapter
lib/rspec/hopper/queue/redis_streams/lua/init.lua
lib/rspec/hopper/queue/redis_streams/lua/transition.lua
lib/rspec/hopper/attempt_log.rb            Event + queries
lib/rspec/hopper/manifest.rb
lib/rspec/hopper/fingerprint.rb
lib/rspec/hopper/example_reset.rb
lib/rspec/hopper/worker.rb                 the RSpec adapter: loop, init/election, completion
lib/rspec/hopper/worker/suite.rb           loads RSpec, discovers units, option checks, seed adoption
lib/rspec/hopper/worker/buffering_reporter.rb
lib/rspec/hopper/worker/heartbeat.rb
lib/rspec/hopper/worker/requeue_policy.rb
lib/rspec/hopper/report.rb                 verdict, exit code, JSON summary
lib/rspec/hopper/ci_env.rb                 build/worker id inference from CI env vars
lib/rspec/hopper/cli.rb                    dispatch: work | report
lib/rspec/hopper/cli/work.rb               OptionParser -> WorkConfig; strips --format/--out for children
lib/rspec/hopper/cli/formatter_args.rb  --format/--out splitting; per-child output files
lib/rspec/hopper/cli/report.rb             OptionParser -> ReportConfig
lib/rspec/hopper/supervisor.rb             --processes N, boot modes, signal forwarding, exit precedence
exe/rspec-hopper
spec/spec_helper.rb                        loads spec/support/**/*.rb
spec/support/redis_helper.rb               TEST redis url, flush helper, key/TTL scan
spec/rspec/hopper/**                       unit specs, mirror lib layout
spec/contract/**                           example_reset, prepend coexistence
spec/fixtures/suites/<name>/               fixture suites (each has .rspec, spec/, optional spec_helper)
spec/integration/**                        spawn real `exe/rspec-hopper work` processes
```

Namespace is `RSpec::Hopper` (capital S). Runtime deps: rspec-core, redis, json only.

## Redis

Test server: `ENV["HOPPER_TEST_REDIS_URL"]`, default `redis://127.0.0.1:6399/0`. Specs
must never touch db 0 on port 6379 by default. Every spec that touches Redis uses a
unique build id (`"spec-#{SecureRandom.hex(6)}"`) and deletes its keys afterwards.

Key layout, all under `hopper:{<build>}:` (`Keys.for(build_id)`):

| key              | type   | notes                                                         |
|------------------|--------|---------------------------------------------------------------|
| `units`          | stream | consumer group `workers`, created at id `0` with MKSTREAM     |
| `units:priority` | stream | same; requeued entries go here                                |
| `attempts`       | stream | attempt log; entries have one field `json`                    |
| `meta`           | hash   | manifest fields + `state`, `ready_at`, `finalized_count`, `requeued_units_count` |
| `unit_state`     | hash   | unit id -> JSON `{"retry_index":0,"reclaim_count":0,"entered_retry":false}` |
| `workers`        | hash   | worker id -> JSON `{"last_seen":<epoch ms int>,"current_unit":<id or null>,"processed":<int>}` |
| `leader`         | string | `<worker_id>:<nonce>`, `SET NX EX 60`, never renewed          |
| `exists`         | string | tombstone, `"1"`, TTL `tombstone_ttl`, never renewed          |

Stream entry fields for a unit: `id` (unit id), `type` (`file`). `attempts` entries:
single field `json`.

`meta` fields (all strings in Redis): `state` (`ready`|`init_failed`), `ready_at`
(epoch ms), `finalized_count`, `requeued_units_count`, `total_units`,
`total_examples`, `file_counts` (JSON object path -> int), `file_args` (JSON array),
`fingerprint`, `seed`, `revision` (may be absent), `load_errors` (JSON array of strings),
`max_requeues`, `requeue_tolerance`, `max_reclaims`, `timeout`, `ttl`. The budget
values are frozen into meta at initialization; the transition script reads them from
`meta` first and falls back to ARGV only when the field is absent, so every worker
enforces the initializer's caps regardless of its own flags. No warning is printed.

TTL rules: every key except `leader` and `exists` gets `PEXPIRE ttl_ms` inside the same
Lua script or MULTI that writes it. `leader` has `EX 60`; `exists` has
`tombstone_ttl`. Reads never touch TTLs. `report` never writes.

Timestamps: Lua uses `redis.call('TIME')` -> epoch milliseconds integer; Ruby passes
nothing clock-related to scripts. Events carry `at_ms`.

### Lua scripts (exactly two)

`init.lua` — KEYS: units, units:priority, attempts, meta, unit_state, leader, exists.
ARGV[1] = mode (`success`|`failure`), ARGV[2] = lease token, ARGV[3] = ttl_ms,
ARGV[4] = tombstone_ttl_ms, ARGV[5] = JSON meta fields (object of string->string),
ARGV[6] = JSON array of unit ids (success only). Aborts with error `LEASE_LOST` if
`leader != token`, `ALREADY_INITIALIZED` if `exists` present, `ALREADY_READY` if `meta`
present. Success: DEL both unit streams, `XGROUP CREATE <s> workers 0 MKSTREAM` on
both, XADD each unit (`id`, `type`), HSET `unit_state` for each unit with zeros,
HSET meta fields + `state=ready`, `ready_at`, `finalized_count=0`,
`requeued_units_count=0`, SET `exists 1 PX tombstone_ttl_ms`, PEXPIRE the rest. Failure
mode: HSET meta fields + `state=init_failed`, `ready_at`, SET tombstone, PEXPIRE.
Returns `"ready"` or `"init_failed"`.

`transition.lua` — KEYS: units, units:priority, attempts, meta, unit_state, workers.
ARGV[1] = mode, ARGV[2] = worker_id, ARGV[3] = ttl_ms, then mode-specific ARGV.
Every mode except `reclaim` receives the handle: stream name (`units` or
`units:priority`), entry_id, delivery_count. The fence: `XPENDING <stream> workers
<entry_id> <entry_id> 1`; if the entry is absent, or its consumer != worker_id, or its
delivery count != handle's, return `{"STALE"}` (a status array, not a Lua error, so the
caller can distinguish it from Redis errors). Any mode that needs `unit_state[unit]` and
finds it missing returns `{"CORRUPT"}`. Any mode that finds `meta` missing (`EXISTS
meta == 0`) returns `{"CORRUPT"}`. All modes end by PEXPIREing every live key that
exists (units, units:priority, attempts, meta, unit_state, workers).

Modes and returns (arrays; first element is a status string):

* `delivery_accounting` ARGV: stream, entry_id, unit_id. Fence by consumer only (delivery
  count is read from XPENDING and returned). Reads unit_state for retry_index and
  reclaim_count, appends `delivered`, HSET workers[worker_id] with `current_unit`. Returns
  `{"OK", delivery_count, retry_index, reclaim_count}`.
* `reclaim` ARGV: timeout_ms, max_reclaims. For each of `units:priority` then `units`:
  `XAUTOCLAIM <stream> workers <worker_id> <timeout_ms> 0-0 COUNT 1`. Reply is
  `{next_id, entries}` on 6.2 and `{next_id, entries, deleted_ids}` on 7+; entries may
  contain `false`/nil placeholders for deleted entries on 6.2 — skip those. If an entry
  is claimed: read its fields, XPENDING for delivery_count, read unit_state (CORRUPT if
  missing). `previous_worker_id` is unknown after XAUTOCLAIM has moved ownership, so the
  script reads `XPENDING` *before* XAUTOCLAIM for the oldest idle entry of the stream
  (`XPENDING <stream> workers IDLE <timeout_ms> - + 1`) to learn the candidate and its
  consumer, then XAUTOCLAIMs; if XAUTOCLAIM returned a different entry than the
  candidate, use whatever XAUTOCLAIM returned and record previous_worker_id as the
  XPENDING result only when the ids match, else `null`. If `reclaim_count + 1 >
  max_reclaims`: XACK the entry, append `finalized` with outcome `failed`, reason
  `reclaim_budget_exhausted`, `HINCRBY meta finalized_count 1`, and return
  `{"FINALIZED", unit_id}`. Otherwise increment reclaim_count in unit_state, append
  `reclaimed` (with `previous_worker_id`), set workers[worker_id].current_unit, return
  `{"OK", stream, entry_id, unit_id, unit_type, delivery_count, retry_index, reclaim_count}`.
  If nothing was claimed from either stream return `{"NONE"}`.
* `heartbeat` ARGV: stream, entry_id, delivery_count, unit_id. Fence; `XCLAIM <stream>
  workers <worker_id> 0 <entry_id> JUSTID`; HSET workers[worker_id] last_seen/current_unit.
  Returns `{"OK"}`.
* `finalize` ARGV: stream, entry_id, delivery_count, unit_id, outcome, duration_ms,
  reason (may be empty), errors_json (may be empty; already size-capped by Ruby).
  Fence; XACK; append `finalized`; `HINCRBY meta finalized_count 1`; HSET
  workers[worker_id] with current_unit null and processed+1. Returns `{"OK"}`.
* `requeue` ARGV: stream, entry_id, delivery_count, unit_id, unit_type, max_requeues,
  requeue_tolerance (string float), duration_ms, failure_summary, errors_json. Fence;
  read unit_state (CORRUPT if missing); `max_requeued = ceil(total_units * tolerance)`;
  if `retry_index + 1 > max_requeues` or (`entered_retry == false` and
  `requeued_units_count >= max_requeued`): behave exactly like `finalize` with outcome
  `failed`, reason `retry_budget_exhausted`, and return `{"FINALIZED", retry_index}`.
  Otherwise: if not entered_retry, set it and `HINCRBY meta requeued_units_count 1`;
  retry_index += 1; write unit_state; XACK old entry; XADD `units:priority` `id`, `type`;
  append `requeued` (carries `failure_summary`, `errors`, `previous_retry_index`; its
  `retry_index` is the post-increment value); HSET workers[worker_id] current_unit null,
  processed+1. Returns `{"REQUEUED", new_retry_index}`.
* `liveness` ARGV: current_unit (may be empty). HSET workers[worker_id] last_seen (+
  current_unit) and PEXPIRE live keys. Returns `{"OK"}`. (Idle-loop liveness; the spec's
  "atomically with a TTL renewal".) If `meta` is missing return `{"CORRUPT"}`.
* `abandoned` ARGV: handle + elapsed_ms. Fenced; appends `abandoned`. Returns `{"OK"}`.
* `worker_error` ARGV: json event (built in Ruby, the script only stamps `at_ms`),
  appends to attempts, PEXPIRE. Returns `{"OK"}`. Does not check meta (may be called
  before ready, e.g. boot errors after another worker initialized; if `attempts` does not
  exist yet the XADD creates it and PEXPIRE covers it).
* `stale_rejected` ARGV: json event; same as worker_error.

Event JSON built inside Lua uses `cjson.encode` of a table; Ruby-built payloads are
passed pre-encoded and embedded as raw JSON strings (concatenate, do not double-encode).
`unit_id`, `worker_id`, `retry_index`, `reclaim_count`, `ownership_generation`
(= 1 + retry_index + reclaim_count), `at_ms`, `type` on every unit-scoped event.

### Ruby interface: `RSpec::Hopper::Queue::RedisStreams`

```ruby
Queue::RedisStreams.new(redis:, build_id:, ttl:, tombstone_ttl:, timeout:,
                        max_requeues:, requeue_tolerance:, max_reclaims:)
```
All keyword args except `redis:`/`build_id:` default to the product-spec defaults. Times
in seconds (Integer/Float); the adapter converts to ms.

| method | returns / raises |
|---|---|
| `status` | `Queue::Status.new(state:, tombstone:, meta:)` — `state` is `nil`, `"ready"` or `"init_failed"`; `meta` a Hash of strings or nil. One MULTI. |
| `acquire_leader(worker_id)` | lease token String or nil |
| `initialize_build(token:, manifest:, unit_ids:)` | `:ready`; raises `LeaseLost`, `PreviouslyInitialized` (tombstone), `AlreadyInitialized` (meta present) |
| `fail_initialization(token:, manifest:)` | `:init_failed`; same raises. `manifest.load_errors` non-empty. |
| `manifest` | `Manifest` or nil |
| `reclaim_lost(worker_id)` | `Reservation` or nil (nil also when the script finalized a unit as reclaim_budget_exhausted; that outcome is in the attempt log) |
| `reserve(worker_id, block_ms: 1000)` | `Reservation` or nil. XREADGROUP priority (no block) then units (BLOCK block_ms), then delivery_accounting. If accounting returns STALE (someone reclaimed it between read and accounting), return nil. |
| `heartbeat(reservation)` | `true`; raises `StaleReservation`, `CorruptBuild` |
| `finalize(reservation, outcome:, duration_ms:, reason: nil, errors: nil)` | `true`; raises `StaleReservation`, `CorruptBuild`. `outcome` is `:passed`/`:failed`; `reason` one of `test_failure`, `retry_budget_exhausted`, `reclaim_budget_exhausted` (required when failed); `errors` an Array of Hashes (see error payload) capped by `ErrorPayload.cap`. |
| `requeue(reservation, duration_ms:, failure_summary:, errors:)` | `Queue::RequeueResult.new(status:, retry_index:)` with status `:requeued` or `:finalized`; raises `StaleReservation`, `CorruptBuild` |
| `record_worker_error(worker_id:, phase:, error:, unit_id: nil)` | `true`. `phase` in `boot init reserve execution redis formatter`. Builds the event in Ruby from an Exception (class, capped message, capped backtrace). |
| `record_stale_rejected(reservation, operation:)` | `true` |
| `touch_liveness(worker_id, current_unit: nil)` | `true`; raises `CorruptBuild` if meta gone |
| `complete?` | `true`/`false`; raises `BuildStateMissing` if meta gone |
| `finalized_count`, `total_units` | Integer; raise `BuildStateMissing` if meta gone |
| `attempt_events` | `Array<Hash>` (symbol keys? NO — string keys, exactly as decoded from JSON) in stream order |
| `workers` | `Hash<String, Hash>` worker id -> `{"last_seen"=>ms, "current_unit"=>..., "processed"=>n}` |
| `unit_states` | `Hash<String, Hash>` unit id -> `{"retry_index"=>, "reclaim_count"=>, "entered_retry"=>}` |
| `keys` | Array of the build's existing key names (for TTL scans, via SCAN MATCH `hopper:{build}:*`) |

`Reservation = Data.define(:unit_id, :unit_type, :stream, :entry_id, :consumer,
:delivery_count, :retry_index, :reclaim_count)` with `#ownership_generation` and `#unit`.
`stream` holds the *short* name (`"units"` / `"units:priority"`); the adapter maps to
full keys.

Error payload (Ruby side, `ErrorPayload` in errors.rb): array of
`{"example_id"=>, "description"=>, "class"=>, "message"=>, "backtrace"=>[...]}`; message
capped at 4 KiB, backtrace at 20 lines, whole array JSON capped at 64 KiB (drop trailing
entries and append `{"truncated"=>n}`).

### Redis error mapping

`Redis::CannotConnectError`, `Redis::ConnectionError`, `Redis::TimeoutError` are
wrapped by the *worker/report* into `RedisUnreachable` (exit 2); the queue does not
retry. Script replies `{"STALE"}`/`{"CORRUPT"}` map to `StaleReservation`/`CorruptBuild`.

## Attempt log

`AttemptLog.new(events)` where events are the string-keyed hashes from
`queue.attempt_events`. `AttemptLog::Event` is a thin wrapper (`type`, `unit_id`,
`worker_id`, `retry_index`, `reclaim_count`, `ownership_generation`, `at_ms`, `[]`).

Queries (all return plain Ruby, deterministic order = first appearance in the log):

* `failed` -> `[{unit_id:, reason:, worker_id:, errors:}]` units whose last `finalized` is failed.
* `flaky` -> unit ids with >= 1 `requeued` and final `finalized` passed.
* `never_finalized(unit_ids)` -> `[{unit_id:, last_worker_id:}]` for manifest units with no `finalized`; `last_worker_id` from the latest `delivered`/`reclaimed`, or nil.
* `abandoned` -> unit ids with an `abandoned` event.
* `retry_counts` -> `{unit_id => max retry_index seen in requeued events}` (only units with >= 1 requeue).
* `reclaim_counts` -> `{unit_id => count of reclaimed events}` (only units with >= 1).
* `worker_errors` -> array of the raw `worker_error` events.
* `stale_rejections` -> raw `stale_rejected` events.
* `finalized_events(unit_id)` -> array (property spec: exactly one per unit).
* `to_a` -> events.

A unit reclaimed and then passing with no `requeued` event is not flaky.

## Manifest

`Manifest = Data.define(:total_units, :total_examples, :file_counts, :file_args,
:fingerprint, :seed, :ready_at, :revision, :load_errors)` — `#unit_ids` is derived: the
keys of `file_counts` in order (`total_units == unit_ids.size`).
`#to_meta` -> Hash of String->String for HSET (JSON-encoding the nested fields);
`Manifest.from_meta(hash)` inverse (ignores the extra runtime fields). `ready_at` is
epoch ms set by Redis; before publication it's nil.

## Worker (RSpec adapter)

`Worker.new(config:, queue_factory:, out: $stdout, err: $stderr)` and `#run` returns an
exit code (0, 2). `queue_factory` is a lambda returning a `Queue::RedisStreams` so the
worker can open Redis only after the suite boots (and the supervisor can pass a lambda to
children). Sequence:

1. `Suite.new(rspec_args, config)`: `ConfigurationOptions.new(args)`; reject `--init`
   from raw argv/`SPEC_OPTS`; `options.options[:bisect]`/`[:drb]` -> `UnsupportedOption`;
   `options.configure(RSpec.configuration)`; then check `configuration.fail_fast`,
   `only_failures?` (covers `--next-failure`), `dry_run?` -> `UnsupportedOption`.
   Register a `:message` listener on `RSpec.configuration.reporter` to capture load
   errors (`Reporter#notify_non_example_exception` emits `message`), then
   `configuration.load_spec_files`; `RSpec.world.wants_to_quit || rspec_is_quitting`
   with captured messages => `load_errors`. Any other exception during boot is phase
   `boot` -> exit 2.
2. Units: `RSpec.world.ordered_example_groups` (top-level, in configured order); a unit
   is every distinct `group.metadata[:file_path]` whose `descendant_filtered_examples`
   is non-empty; file counts are `descendant_filtered_examples.size` summed per file;
   unit id is `metadata[:file_path]` verbatim (`./spec/...`). Example ids for the
   fingerprint are `example.id` over `RSpec.world.all_examples` filtered to the selected
   set (`group.descendant_filtered_examples` across all top-level groups).
3. Fingerprint (`Fingerprint.compute(configuration:, options:, revision:)`): SHA256 over
   a canonical JSON of `{file_args: sorted, filter: inclusion+exclusion rules as
   strings, pattern:, exclude_pattern:, order: configuration.ordering_registry ... name
   (`RSpec.configuration.ordering_manager` exposes `seed_used?`/`order`; derive the
   strategy name from `configuration.ordering_manager.instance_variable_get`? NO —
   use the merged option `options.options[:order]` string minus any `:seed` suffix, or
   `"defined"` when absent), example_ids: sorted, revision:}`. Also returns the
   `inputs` hash so a mismatch message can diff them (`Fingerprint::Mismatch#explain`).
4. Election/join per product spec; `config.init_timeout` bounds it. After `ready`:
   compare fingerprint; `RSpec.configuration.seed = manifest.seed`.
5. `RSpec.configuration.reporter.report(total_selected_examples_for_this_worker?)` —
   NO: the outer reporter lifecycle is `reporter.start(expected_count)` with the
   manifest's `total_examples`, `configuration.with_suite_hooks { loop }`, then
   `reporter.finish`. Use `report(n) { ... }` from Runner so `start`/`finish`/`close` fire
   once. The runner subclasses `RSpec::Core::Runner` (`Worker::Runner`) and overrides
   `run_specs` to run the hopper loop; `setup` is reused for configure+load.
6. Loop: `queue.reclaim_lost(w) || queue.reserve(w)`; nil -> `touch_liveness`, check
   `complete?` (raise `BuildStateMissing` -> exit 2), check `Process.ppid` if
   supervised, continue. With a reservation: `ExampleReset.reset(groups)` if
   `reservation.ownership_generation > 1` OR the process has run these groups before
   (simplest: always reset before running; the reset is idempotent on fresh examples —
   do it always), start `Heartbeat`, run each top-level group for the unit through
   `group.run(buffering_reporter)` in `ordered_example_groups` order, stop heartbeat,
   then `RequeuePolicy.decide(examples)`.
7. `RequeuePolicy`: collect `execution_result` of the unit's selected examples; failed
   examples' `exception` (and for `RSpec::Core::MultipleExceptionError`, `all_exceptions`)
   must all be requeueable (`not SystemExit/Interrupt/SignalException/NoMemoryError`);
   `passed?` if no failures. Decision `:passed`, `:requeue_candidate`, `:final_failure`.
8. Passed -> `queue.finalize(passed)`, replay buffer. Final failure ->
   `queue.finalize(failed, reason: test_failure, errors:)`, replay. Requeue candidate ->
   `queue.requeue(...)`; `:requeued` -> discard buffer, print
   `Retrying <unit> (retry <i> of <max>; next attempt <i+1>): <n> failure(s)`;
   `:finalized` -> replay buffer. `StaleReservation` -> discard buffer,
   `record_stale_rejected`, continue. `CorruptBuild` -> `record_worker_error(phase:
   redis)` and exit 2.
9. Completion: `complete?` true -> exit loop; `reporter.finish` via `report`; return 0.

`BufferingReporter` responds to `example_group_started/finished`, `example_started`,
`example_finished`, `example_passed/failed/pending`, `fail_fast_limit_met?` (false),
`message`, `publish`, `notify_non_example_exception`, `deprecation` — everything RSpec may
call on it from `ExampleGroup.run`/`Example#run`; records `[method, args]`; `replay(real)`
sends each in order; `discard`. It must NOT forward `report`/`start`/`finish`/`close`.
Note `Example#run` also calls `reporter.example_started(self)` etc. via `start`/`finish`
— buffer them all. `Reporter#example_finished` is what the profiler listens to;
`example_failed` increments `@failed_examples` on the real reporter, so a replayed
failure still fails `dump_summary` — correct.

`Heartbeat.new(queue:, reservation:, config:, out:, clock:)`; `#start`/`#stop`; thread:
every `min(timeout/3, 30)` s call `queue.heartbeat(reservation)` (swallow
`StaleReservation`: stop heartbeating, flag `stale` so the runner knows the result
will be rejected — still let the unit finish; the finalize will get STALE anyway).
After `max_unit_duration` elapsed: `queue.record_abandoned(reservation, elapsed_ms:)`
(one more queue verb; the script mode `abandoned` appends the event, fenced), stop
renewing; after a further `timeout`: print `Aborting worker: <unit> exceeded <s>s` to
`err`, flush, `exit!(4)`.

`ExampleReset.reset(example_groups)` — for each group and all descendants, for each
`filtered_examples`: `instance_variable_set(:@exception, nil)`,
`metadata[:execution_result] = RSpec::Core::Example::ExecutionResult.new`. Pinned
ivar list after a run under bare rspec-core 3.13.6:
`[:@clock, :@example_block, :@example_group_class, :@example_group_instance,
:@exception, :@id, :@metadata, :@reporter]`.

## Report

`Report.new(config:, queue:, clock:, sleeper:)`, `#run(out:)` -> exit code; `#summary`
-> Hash for JSON. Wait phases per product spec. Inactivity: `now - max(ready_at,
workers.values.map(last_seen).max) > inactive_timeout` -> exit 3. The `--timeout`
default is 1080 s. JSON summary schema:

```json
{"build_id": "...", "state": "ready", "verdict": "passed|failed|incomplete|init_failed|missing|expired",
 "exit_code": 0, "total_units": 12, "total_examples": 340, "finalized_count": 12,
 "failed": [{"unit_id":..., "reason":..., "worker_id":..., "errors":[...]}],
 "flaky": ["./spec/..."], "never_finalized": [{"unit_id":..., "last_worker_id":...}],
 "abandoned": ["..."], "retry_counts": {...}, "reclaim_counts": {...},
 "worker_errors": [...], "stale_rejections": 0, "workers": {...}, "load_errors": [...],
 "file_args": [...], "seed": 1234, "fingerprint": "...", "revision": null}
```
The summary also carries a `message` headline, and the verdict `unreachable` (exit 2)
when Redis cannot be reached. `--failed-out` writes one unit id per line (failed +
never_finalized).

## Config

```ruby
WorkConfig = Data.define(:build_id, :worker_id, :redis_url, :timeout, :max_unit_duration,
  :max_requeues, :requeue_tolerance, :max_reclaims, :processes, :boot, :report_on_exit,
  :ttl, :tombstone_ttl, :init_timeout, :revision, :rspec_args, :report_args, :supervised)
ReportConfig = Data.define(:build_id, :redis_url, :timeout, :init_timeout,
  :inactive_timeout, :summary_out, :failed_out, :allow_empty, :min_examples)
```
Defaults live in `Config::DEFAULTS`. `boot` is `:per_process` or `:shared`.
`rspec_args` is the array after the gem's own flags (everything OptionParser did not
consume, plus everything after `--`). `report_args` are the raw args for the parent's
`--report-on-exit` report (built from the work flags: build, redis).

Exit codes: `ExitCode::OK = 0, TEST_FAILURE = 1, INFRASTRUCTURE = 2, INCOMPLETE = 3,
ABORTED = 4` in errors.rb.

## Conventions

* rubocop (`.rubocop.yml` at root) must pass: `bundle exec rubocop`. Run it on your
  files before finishing. Line length 120.
* Specs: `bundle exec rspec spec/rspec/hopper/...`. Redis specs need the test server;
  tag them `:redis` and `spec_helper` skips them with a clear message if the server is
  unreachable.
* No `Marshal`, no globals, no `RSpec.configuration` mutation outside `Worker::Suite`.
* Frozen string literals everywhere. Ruby >= 3.2 syntax only (Data.define ok).
* Do not commit. The integrator commits.
