# rspec-hopper

rspec-hopper distributes an RSpec suite across many CI workers through a shared
Redis, requeues flaky work, reclaims work from workers that die, and produces one
authoritative pass/fail verdict for the whole build.

A hopper feeds a machine continuously: workers pull spec files from a shared queue as
fast as they finish them, and requeued files drop back in ahead of untouched work.
There is no up-front partitioning, so a slow file or a slow machine only delays its
own share of the work.

## Problems it solves

Each of these is a failure mode of the "share a queue in Redis and let every worker
exit with its own status" approach as it exists in other tools:

- **Leaked Redis keys.** Every key the gem writes gets its TTL in the same atomic
  operation that creates it. Killed workers cannot leave keys behind forever.
- **False green on an empty or vanished queue.** A build whose keys expired, a suite
  that selected zero examples, and a build that finished all look like "nothing left to
  run". The report tells them apart and only passes when a published manifest exists
  and every unit in it finalized as passed.
- **Fighting other gems over RSpec internals.** Nothing is prepended onto
  `RSpec::Core::Example#run`, `#start` or `#finish`, so instrumentation gems that do
  (datadog-ci, rspec-retry and others) keep working.
- **Ambiguous exit codes.** Workers exit 0 on completion regardless of test results;
  `rspec-hopper report` is the single place a build's verdict comes from.
- **`Marshal.load` from a shared Redis.** Everything stored is JSON.
- **One process per worker.** `--processes N` runs several workers on one machine,
  optionally sharing one application boot.
- **No `before(:all)` support.** Whole example groups run through
  `ExampleGroup.run`, so context hooks fire as they do under plain `rspec`.
- **Global mutable configuration.** The gem parses its own flags into a frozen config
  and hands everything else to RSpec's option parser untouched.

## Installation

Add the gem to the test group of your `Gemfile`:

```ruby
group :test do
  gem "rspec-hopper"
end
```

Then `bundle install`. Requirements are listed under [Supported versions](#supported-versions).

## Quick start

Run one worker on every CI node. All workers of one CI run share a build id; each
has a distinct worker id. Everything after `--` (and any argument the gem does not
recognise) goes to RSpec unchanged.

```sh
# on each of N nodes
bundle exec rspec-hopper work \
  --build "$CI_BUILD_ID" --worker "$CI_NODE_INDEX" --redis "$REDIS_URL" \
  --max-requeues 2 --requeue-tolerance 0.05 \
  --format RspecJunitFormatter --out tmp/junit.xml -- spec
```

Then, from any node or a final job, ask for the verdict. `report` never loads the
application or the spec files; it only reads Redis, and it can be started before any
worker.

```sh
bundle exec rspec-hopper report \
  --build "$CI_BUILD_ID" --redis "$REDIS_URL" \
  --summary-out tmp/hopper-summary.json --failed-out tmp/hopper-failed.txt
```

The report's exit code is the build's result. Use it as the CI job's status. The
`--failed-out` file holds one spec file per line (failed and never-finalized units), so
`bundle exec rspec $(cat tmp/hopper-failed.txt)` reruns them locally.

`--build`, `--worker` and `--redis` can be omitted when `HOPPER_BUILD_ID`,
`HOPPER_WORKER_ID` and `HOPPER_REDIS_URL` (or `REDIS_URL`) are set, and the build and
worker ids fall back to the CI variables listed under
[CI environment inference](#ci-environment-inference). When nothing names the
worker, `<hostname>-<pid>` is used.

## How it works

1. Every worker boots the application and loads the spec files with RSpec, exactly as
   `rspec` would, applying `.rspec`, `~/.rspec`, `SPEC_OPTS` and the command line.
2. The first worker to take a short lease publishes the build: one **unit** per spec
   file that has at least one selected example, plus a manifest (unit and example
   counts, the file arguments, the suite fingerprint, the seed). Every other worker
   waits for the manifest, then checks that its own suite fingerprint matches.
3. Workers loop: reclaim a unit whose owner stopped heartbeating, or reserve the next
   unit (requeued units first), run all of that file's top-level example groups through
   `ExampleGroup.run`, then finalize the unit as passed or failed, or requeue it.
4. Formatter output is buffered per attempt and replayed only for the final attempt,
   so JUnit and JSON files contain each example exactly once. Flakiness is recorded in
   the attempt log, not in formatter output.
5. A worker exits only when every unit of the manifest has been finalized. An empty
   queue is never treated as completion, so idle workers stay available to reclaim
   units from workers that die late.
6. `report` waits for the same condition and turns the attempt log into a verdict.

## Correctness invariants

These hold regardless of worker crashes, hung tests, or Redis trouble:

- Every selected unit reaches exactly one final state, passed or failed.
- Execution may happen more than once after a worker is lost; finalization happens
  exactly once. A worker whose ownership was reclaimed can no longer finalize,
  requeue or heartbeat that attempt; its result is discarded and recorded as
  `stale_rejected`.
- Ownership never moves without reclaim accounting, and there is no crash window
  between the two.
- Re-execution after worker loss never consumes retry budget and never marks a unit
  flaky.
- Completion means `finalized_count == total_units`, never "the queue is empty".
- Once a build is ready, missing build state is corruption. Nothing silently recreates
  it, and a build id whose state has vanished is never reinitialized.
- A build cannot report green unless a manifest was published and every unit in it
  finalized as passed. Zero selected examples fail unless the reporter is given
  `--allow-empty`.
- No Redis key created by the gem exists without a positive TTL.
- Workers with different suite fingerprints never participate in the same build.
- Requeued work is preferred over untouched work.
- Redis, application or worker death and hung tests may delay completion; they cannot
  silently change the verdict or prevent completion indefinitely.

## Suite hooks run once per worker process

`before(:suite)` and `after(:suite)` run once in **every worker process**, not once per
build. With ten workers, a `before(:suite)` that seeds a database runs ten times, and
under `--processes 4` it runs four times per machine. The gem provides no build-global
hook; if something must happen exactly once per build, do it in a CI step before the
workers start.

A `before(:suite)` hook that raises makes that worker exit 2 without running any unit.

## CLI reference

### `rspec-hopper work`

```text
rspec-hopper work --build ID --worker WID --redis URL [options] [rspec args...] -- [files...]
```

| Option | Default | Meaning |
|---|---|---|
| `--build ID` | `$HOPPER_BUILD_ID`, then CI inference | Build id shared by every worker of one CI run. |
| `--worker WID` | `$HOPPER_WORKER_ID`, CI inference, then `<hostname>-<pid>` | This worker's id, unique within the build. |
| `--redis URL` | `$HOPPER_REDIS_URL`, then `$REDIS_URL` | Redis URL. |
| `--revision SHA` | none | String mixed into the suite fingerprint, for example the commit being tested. |
| `--timeout SECONDS` | 180 | Missed-heartbeat window after which an in-flight unit can be reclaimed by another worker. |
| `--max-unit-duration SECONDS` | 900 | After this much execution time a unit is recorded as abandoned and becomes reclaimable even though its owner is alive; the owner aborts itself `--timeout` seconds later. Must exceed the slowest legitimate file. |
| `--max-requeues N` | 0 | Maximum number of retries of any one unit. |
| `--requeue-tolerance R` | 0 | Fraction of units, `0.0` to `1.0`, allowed to enter retry during the build (`ceil(total_units * R)` units). |
| `--max-reclaims N` | 3 | Reclaims from dead or abandoning owners before a unit is finalized as failed. |
| `--processes N` | 1 | Fork N worker processes on this machine. See [Process parallelism](#process-parallelism). |
| `--boot MODE` | `per-process` | `per-process` or `shared`. |
| `--report-on-exit` | off | The `--processes` parent runs `report` after all children exit and uses its exit code. |
| `--ttl SECONDS` | 14400 | Inactivity TTL of the build's live keys. |
| `--tombstone-ttl SECONDS` | 604800 | Lifetime of the build's tombstone (seven days). |
| `--init-timeout SECONDS` | 300 | How long a worker waits for another worker to publish the build. |

Either retry limit at zero disables requeues; the defaults run every file once. The
retry, reclaim and timeout values of the worker that publishes the build are recorded
in the build and enforced for every worker, so give all workers the same flags.

Requeue eligibility: a failed attempt is requeued only if every failure in the file is
requeueable, meaning anything except `SystemExit`, `Interrupt`, `SignalException` and
`NoMemoryError`. One of those anywhere in the file makes the attempt final. When a
retry would exceed `--max-requeues` or the tolerance, the failure is final with reason
`retry_budget_exhausted`. On a requeue the worker prints one line and emits nothing to
formatters:

```text
Retrying ./spec/models/foo_spec.rb (retry 1 of 2; next attempt 2): 1 failure
```

Unsupported RSpec options are rejected with exit 2 and a message naming the option,
wherever they come from (`.rspec`, `~/.rspec`, `SPEC_OPTS` or the command line):
`--fail-fast` (any value), `--only-failures`, `--next-failure`, `--bisect`,
`--dry-run`, `--drb` and `--init`. Each conflicts with every unit reaching a final
state or with distributed execution.

The seed is chosen by the publishing worker (the user's `--seed` if given, otherwise
random) and adopted by every worker, so within-file ordering is identical everywhere.

### `rspec-hopper report`

```text
rspec-hopper report --build ID --redis URL [options]
```

| Option | Default | Meaning |
|---|---|---|
| `--build ID` | `$HOPPER_BUILD_ID` | Build id. |
| `--redis URL` | `$HOPPER_REDIS_URL`, then `$REDIS_URL` | Redis URL. |
| `--timeout S` | 1080 | Give up (exit 3) after S seconds without completion. |
| `--init-timeout S` | 300 | Wait this long for the manifest or tombstone to appear before exiting 2. |
| `--inactive-timeout S` | 300 | Give up (exit 3) once this long has passed since the later of the build becoming ready and the most recent worker activity. |
| `--summary-out PATH` | none | Write the JSON summary to PATH. |
| `--failed-out PATH` | none | Write failed and never-finalized unit ids to PATH, one per line. |
| `--fail-on-empty` | on | Zero selected examples is a failure. |
| `--allow-empty` | off | Zero selected examples may pass. Cannot be combined with a positive `--min-examples`. |
| `--min-examples N` | 0 | Fail unless at least N examples were selected, guarding against a filter that selects almost nothing. |

`report` prints the verdict, unit and example totals, failed and never-finalized units
(with the worker that last held each), flaky and abandoned units, worker errors, and
recorded load errors when initialization failed. Heartbeats from a long-running unit
count as worker activity, so a file slower than `--inactive-timeout` does not trip it.

The JSON summary has these keys: `build_id`, `state`, `verdict` (`passed`, `failed`,
`incomplete`, `init_failed`, `missing`, `expired`, `unreachable`), `exit_code`,
`message`, `total_units`, `total_examples`, `finalized_count`, `failed` (unit id,
reason, worker id, errors), `flaky`, `never_finalized` (unit id, last worker id),
`abandoned`, `retry_counts`, `reclaim_counts`, `worker_errors`, `stale_rejections`,
`workers`, `load_errors`, `file_args`, `seed`, `fingerprint`, `revision`.

## Exit codes

### `work`, single process

| Code | Meaning |
|---|---|
| 0 | The build completed. Says nothing about test results; ask `report`. |
| 2 | Infrastructure failure: boot error, unsupported RSpec option, Redis unreachable, initialization timed out or failed (spec-file load error), previously initialized build id, fingerprint mismatch, build state vanished or corrupt after ready, `--boot shared` without an `after_fork` hook. |
| 4 | The worker aborted itself because a unit ran past `--max-unit-duration` plus `--timeout`. The cause is a test, not infrastructure; the unit was made reclaimable and the verdict still comes from `report`. |

### `work` parent with `--processes N`

Precedence is semantic, not numeric.

| Mode | Exit code |
|---|---|
| without `--report-on-exit` | 2 if any child exited 2 (or died without an exit status, for example killed by a signal); otherwise 4 if any child exited 4; otherwise 0. |
| with `--report-on-exit` | 2 if any child exited 2, and the report is not run. Otherwise the `report` exit code; a child's 4 is logged as diagnostic only, because the verdict on the reclaimed unit belongs to `report`. |

### `report`

| Code | Meaning |
|---|---|
| 0 | Manifest present with state `ready`, examples selected (or `--allow-empty`) and at least `--min-examples`, every unit finalized as passed, `finalized_count == total_units`. |
| 1 | Test failures: at least one unit finalized as failed, or zero examples selected without `--allow-empty`, or fewer than `--min-examples`. |
| 2 | Neither manifest nor tombstone exists after `--init-timeout` (nobody booted), or Redis is unreachable. |
| 3 | The tombstone exists but the manifest is gone (expired or evicted), initialization failed with spec-file load errors, the build was incomplete at `--timeout`, or workers went inactive before completion. |

## Process parallelism

`--processes N` forks N workers on one machine with worker ids `<worker>.1` to
`<worker>.N`. The parent forwards `INT` and `TERM` to the children, waits for all of
them and exits per the precedence above. Children exit if the parent disappears.
`--processes 1` runs inline without forking; N above 1 is refused on platforms without
`fork`.

Each child sets `TEST_ENV_NUMBER` the way `parallel_tests` does: empty for the first
child, `"2"` to `"N"` for the rest. The two boot modes differ in *when* that happens
relative to loading the application.

### `--boot per-process` (default)

The parent parses only the gem's flags and forks immediately. Each child sets
`TEST_ENV_NUMBER`, then applies RSpec options and loads the suite as a standalone
worker would. Everything the application evaluates while loading, such as a database
name built from `TEST_ENV_NUMBER` in `database.yml`, sees the child's value. Boot
happens N times. This mode is correct for any application.

Use it when the application has not been audited for forking, boot is cheap, N is
low, many things consume `TEST_ENV_NUMBER` at boot, or you are debugging a
shared-mode failure.

### `--boot shared` (opt-in)

The parent applies RSpec options and loads the suite once with `TEST_ENV_NUMBER`
unset, runs the `RSpec::Hopper.before_fork` hooks, then forks. Each child sets
`TEST_ENV_NUMBER`, runs the `RSpec::Hopper.after_fork` hooks, runs the suite hooks and
consumes the queue. Boot happens once and children share memory copy-on-write.

Use it when boot is a large share of per-process wall clock and N is high, memory is
the constraint, or the application is already fork-hardened.

The gem cannot make this mode safe on the application's behalf: anything computed from
`TEST_ENV_NUMBER` while the application loaded was computed with it unset. It refuses
to start, with exit 2, unless at least one `after_fork` hook is registered. In the
hooks you must:

- `before_fork`: close every connection opened during boot (database, Redis, HTTP
  keep-alive pools), so children do not inherit shared sockets.
- `after_fork`: re-derive every value that was computed from `TEST_ENV_NUMBER`.
  Common consumers to check: the database name, the Redis database index, search index
  prefixes, the Capybara server port, tmp and storage paths, cache namespaces, log file
  paths, and any client library that read the variable at require time.

Boot-time checks ran once against the base configuration. For example, Rails'
`maintain_test_schema!` verified the schema of the unsuffixed database, not of the
per-child databases; make sure those exist and are migrated before the workers start.

A Rails recipe, in a support file loaded by `rails_helper.rb`. The gem itself has no
Rails dependency; this is host application code:

```ruby
# spec/support/hopper.rb
if defined?(RSpec::Hopper)
  RSpec::Hopper.before_fork do
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  RSpec::Hopper.after_fork do |env_number|
    # Re-read config/database.yml so its ERB sees the child's TEST_ENV_NUMBER,
    # then reconnect. Repeat for each configured database if you use several.
    ActiveRecord::Base.configurations = Rails.application.config.database_configuration
    ActiveRecord::Base.establish_connection(Rails.env.to_sym)
  end
end
```

The hook receives the child's `TEST_ENV_NUMBER` value (`""` or `"2"`..`"N"`); it is
also already set in `ENV`. Registering hooks in single-process or per-process mode is
harmless; they are only run in shared mode.

Add a guard in the host application so a missed consumer fails loudly before any test
touches the wrong database. A `before(:suite)` hook runs in every child before its
first unit, and a failure there makes the worker exit 2:

```ruby
RSpec.configure do |config|
  config.before(:suite) do
    suffix = ENV.fetch("TEST_ENV_NUMBER", "")
    database = ActiveRecord::Base.connection.current_database
    unless database.end_with?(suffix)
      raise "worker #{ENV["TEST_ENV_NUMBER"].inspect} is connected to #{database}"
    end
  end
end
```

### Formatter output per child

The parent strips every `--format` and `--out` option from the RSpec arguments and
applies them in each child, substituting `%{n}` in `--out` paths with the child's
`TEST_ENV_NUMBER`:

```sh
rspec-hopper work --processes 4 --build "$B" --worker "$W" --redis "$R" \
  --format RspecJunitFormatter --out "tmp/junit-%{n}.xml" -- spec
```

produces `tmp/junit-.xml`, `tmp/junit-2.xml`, `tmp/junit-3.xml` and
`tmp/junit-4.xml`. Without the placeholder every child writes the same file and the
last one wins.

A formatter that is given no `--out` of its own gets one: children write to
`tmp/rspec-hopper/<worker id>-<formatter>.<ext>`, and a run with no `--format` at all
gets a `progress` formatter pointed at that directory. Above one process, therefore,
nothing but hopper's own log lines reaches the console.

That is deliberate. Each child runs only its share of the build, so a per-process RSpec
summary describes a fragment, and a child that reserved nothing prints
`0 examples, 0 failures` for a build that may have failed. The closing word belongs to
`rspec-hopper report`, which is the only thing that sees every worker's results; run it
as a final CI step, or pass `--report-on-exit` to have the parent run it and adopt its
exit code. Console formatters such as `documentation` still interleave unreadably if
you point several children at the console yourself.

With `--processes 1` (the default) nothing is redirected: one worker owns the console
and prints its summary as plain `rspec` would.

## Retries, reclaims and per-unit counters

Each unit carries three counters, all visible in the attempt log:

| Counter | Starts at | Increments when | Compared against |
|---|---|---|---|
| `retry_index` | 0 | A completed attempt failed with only requeueable exceptions and the caps allowed a requeue. | `--max-requeues` |
| `reclaim_count` | 0 | Another worker took the unit from an owner that stopped heartbeating (dead, stopped, or past `--max-unit-duration`). Survives retries. | `--max-reclaims` |
| `ownership_generation` | 1 | Derived: `1 + retry_index + reclaim_count`. Identifies the logical owner across the stream entry being replaced on retry. | nothing |

Reclaiming never consumes retry budget, and a unit that is reclaimed after a worker
death and then passes is not flaky. A unit reclaimed more than `--max-reclaims` times
is finalized as failed with reason `reclaim_budget_exhausted`, so a file that crashes
every process that runs it cannot stall the build.

Hung tests: while a unit runs, a heartbeat thread renews its reservation every
`min(--timeout / 3, 30)` seconds. Once the unit has run for `--max-unit-duration`, the
thread records an `abandoned` event and stops renewing, so the unit becomes
reclaimable after a further `--timeout` seconds whether or not the process is alive.
After that same window the worker prints `Aborting worker: ./spec/foo_spec.rb exceeded
900s` and exits 4, because the hung test thread cannot be interrupted safely. A unit
that finishes inside the window finalizes normally and the `abandoned` event stands as
a warning.

## Attempt log

`hopper:{<build>}:attempts` is a Redis stream of JSON events, one per stream entry
(field `json`). `report` derives everything it says from it, and you can read it
yourself with `XRANGE`.

Every unit-scoped event carries `type`, `unit_id`, `worker_id`, `retry_index`,
`reclaim_count`, `ownership_generation` and `at_ms` (epoch milliseconds stamped by
Redis). Additional fields per type:

| Type | Meaning | Additional fields |
|---|---|---|
| `delivered` | A worker reserved the unit and completed delivery accounting. | `stream`, `entry_id`, `delivery_count` |
| `reclaimed` | A worker took the unit from an owner that stopped heartbeating. | `previous_worker_id` (null when it could not be determined), `stream`, `entry_id`, `delivery_count` |
| `requeued` | A failed attempt was requeued; `retry_index` is the new value. | `previous_retry_index`, `duration_ms`, `failure_summary`, `errors`, `stream`, `entry_id`, `new_entry_id` |
| `abandoned` | The unit exceeded `--max-unit-duration`; the owner stopped heartbeating. A warning, not a terminal state. | `elapsed_ms`, `stream`, `entry_id` |
| `finalized` | Terminal. | `outcome` (`passed` or `failed`), `duration_ms`, `reason` (`test_failure`, `retry_budget_exhausted` or `reclaim_budget_exhausted`; null when passed), `errors` (null when passed), `stream`, `entry_id`; `failure_summary` when the retry budget was exhausted; `previous_worker_id` and `delivery_count` when the reclaim budget was exhausted |
| `stale_rejected` | A worker's finalize or requeue was refused because ownership had moved; its result was discarded. | `operation`, `stream`, `entry_id`, `delivery_count` |
| `worker_error` | A non-example worker failure. Not unit-scoped. | `worker_id`, `phase` (`boot`, `init`, `reserve`, `execution`, `redis`, `formatter`), `unit_id` (null when unknown), `class`, `message`, `backtrace`, `at_ms` |

`errors` is an array of `{example_id, description, class, message, backtrace}`
objects. Messages are capped at 4 KiB and backtraces at 20 lines; if the array would
exceed 64 KiB, trailing entries are dropped and a final `{"truncated": n}` entry says
how many.

A unit is **failed** when its last `finalized` event has outcome `failed`, **flaky**
when it has at least one `requeued` event and its last `finalized` event is `passed`,
**never finalized** when the manifest lists it and no `finalized` event exists, and
**abandoned** when an `abandoned` event exists.

## Redis key layout and TTLs

All keys live under `hopper:{<build>}:`. The braces are a Redis Cluster hash tag so a
build's keys share one slot; Cluster itself is not supported in Phase 1.

| Key | Type | Contents | TTL |
|---|---|---|---|
| `units` | stream | One entry per unit (`id`, `type`), consumer group `workers`. | inactivity (`--ttl`) |
| `units:priority` | stream | Requeued units, read before `units`. Consumer group `workers`. | inactivity |
| `attempts` | stream | The attempt log. | inactivity |
| `meta` | hash | Manifest fields (`total_units`, `total_examples`, `file_counts`, `file_args`, `fingerprint`, `seed`, `revision`, `load_errors`), `state` (`ready` or `init_failed`), `ready_at`, `finalized_count`, `requeued_units_count`, and the recorded `max_requeues`, `requeue_tolerance`, `max_reclaims`, `timeout` and `ttl`. | inactivity |
| `unit_state` | hash | Unit id to `{"retry_index", "reclaim_count", "entered_retry"}`. | inactivity |
| `workers` | hash | Worker id to `{"last_seen", "current_unit", "processed"}`. | inactivity |
| `leader` | string | Initialization lease, `<worker>:<nonce>`. | 60 s fixed, never renewed |
| `exists` | string | Tombstone, `"1"`. | `--tombstone-ttl`, never renewed |

The inactivity TTL (`--ttl`, default four hours) is set atomically with every write
that creates or could recreate a key, and renewed by every heartbeat, finalization,
requeue, reclaim and idle liveness update. A long build stays alive while anyone is
working and expires after the configured idle period. The tombstone outlives the
working keys so that `report` can tell "this build ran and its keys expired" (exit 3)
from "this build never existed" (exit 2), and so that a build id whose state vanished
is never reseeded. Reuse of a build id is therefore refused for the tombstone's
lifetime; generate a fresh id per CI run.

The gem never deletes a build's keys; they expire. Budget Redis memory for the number
of builds that start within one `--ttl` window.

## CI environment inference

When `--build` or `--worker` is omitted and `HOPPER_BUILD_ID` / `HOPPER_WORKER_ID` are
unset, the ids are read from the first detected vendor. This is the gem's only
CI-vendor awareness.

| Vendor | Detected by | Build id from | Worker id from |
|---|---|---|---|
| CircleCI | `CIRCLECI` | `CIRCLE_WORKFLOW_ID`, else `CIRCLE_BUILD_NUM` | `CIRCLE_NODE_INDEX` |
| Buildkite | `BUILDKITE` | `BUILDKITE_BUILD_ID` | `BUILDKITE_PARALLEL_JOB` |
| GitHub Actions | `GITHUB_ACTIONS` | `GITHUB_RUN_ID`-`GITHUB_RUN_ATTEMPT` | none; set `--worker` or `HOPPER_WORKER_ID` from your matrix |
| GitLab CI | `GITLAB_CI` | `CI_PIPELINE_ID` | `CI_NODE_INDEX` |

On GitHub Actions the run attempt is part of the build id so that a re-run of the
workflow does not collide with the tombstone of the previous attempt. On the other
vendors, re-running a job reuses the same build id; if the previous run's tombstone
still exists the workers exit 2 with "previously initialized", so pass a fresh
`--build` (for example with a retry counter appended) when re-running.

## Supported versions

- Ruby 3.2 or newer.
- `rspec-core` 3.12 up to, but not including, 4.0.
- `redis` (redis-rb) 5.x. 6.x is not yet supported.
- Redis server 6.2 or newer (`XAUTOCLAIM` and effects-replicated scripts), or Valkey.
  Standalone or primary-replica deployments only; Redis Cluster is untested and
  unsupported.
- Runtime dependencies are `rspec-core`, `redis` and `json` only.

## Development

```sh
bin/setup                 # bundle install
bin/test-redis            # start a throwaway redis-server on port 6399 (bin/test-redis stop to stop it)
docker compose up -d redis                        # or Redis 7 in Docker on the same port
docker compose --profile valkey up -d valkey      # or Valkey
docker compose --profile redis62 up -d redis62    # or Redis 6.2 (XAUTOCLAIM reply shape)
bundle exec rake          # specs, then rubocop
```

Specs that need Redis are tagged `:redis`, use `HOPPER_TEST_REDIS_URL` (default
`redis://127.0.0.1:6399/0`) and are skipped with a message when no server answers.
Integration specs under `spec/integration` spawn real `rspec-hopper` processes against
the fixture suites in `spec/fixtures/suites`. CI runs the suite on Ruby 3.2 through
4.0 against Redis 7, plus Redis 6.2 and Valkey on the newest Ruby.

## Phase 1 non-goals

- Example-level units or splitting slow files; a unit is a whole spec file.
- Retrying only the failed examples within a file; a requeue reruns the file.
- Timing-based ordering or scheduling.
- Metrics emission.
- Compatibility with ci-queue's flags.
- RSpec 4, redis-rb 6, Redis Cluster.
- Early exit for idle workers before the build completes.
- Build-global suite hooks.
- The rejected RSpec options.

## Prior art

Shopify's [ci-queue](https://github.com/Shopify/ci-queue) established the idea of
feeding RSpec and Minitest workers from a shared Redis queue with requeues for flaky
tests, and much of what rspec-hopper does is a response to running it at scale: key
leaks under `volatile-lru`, empty-queue false greens, method-prepend collisions with
other instrumentation, per-worker exit codes, and `Marshal` over the wire. rspec-hopper
is a from-scratch design around those failure modes rather than a fork, and shares
neither code nor a compatible command line.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
