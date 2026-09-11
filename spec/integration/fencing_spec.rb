# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# Initialization fencing, suite fingerprints, expired builds, unsupported
# RSpec options and the requeue tolerance, all driven through real
# `rspec-hopper work` / `report` processes against the test Redis.
RSpec.describe "build fencing and verdict guards", :integration, :redis do
  let(:redis_url) { HopperSpec::RedisHelper.url }
  let(:redis) { HopperSpec::RedisHelper.new_connection }
  let(:build) { HopperSpec::RedisHelper.build_id("fence") }
  let(:keys) { RSpec::Hopper::Keys.new(build) }

  after do
    HopperSpec::RedisHelper.delete_build(redis, build)
    redis.close
  end

  def run_worker(fixture, worker_id: "w1", args: [], env: {}, extra_rspec_args: [], timeout: 30)
    HopperSpec::Fixtures.run_and_wait(
      fixture: fixture, build_id: build, worker_id: worker_id, redis_url: redis_url,
      args: args, env: env, extra_rspec_args: extra_rspec_args, timeout: timeout
    )
  end

  def spawn_worker(fixture, worker_id: "w1", args: [], env: {}, extra_rspec_args: [])
    HopperSpec::Fixtures.spawn_worker(
      fixture: fixture, build_id: build, worker_id: worker_id, redis_url: redis_url,
      args: args, env: env, extra_rspec_args: extra_rspec_args
    )
  end

  def run_report(args: [], timeout: 30)
    HopperSpec::Fixtures.run_report_and_wait(build_id: build, redis_url: redis_url, args: args, timeout: timeout)
  end

  # Polls until the block returns a truthy value; raises with `what` on timeout.
  def wait_until(what, timeout: 10, interval: 0.05)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      value = yield
      return value if value
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "timed out after #{timeout}s waiting for #{what}"
      end

      sleep interval
    end
  end

  # The attempt log straight from the stream, so it can be read while meta is gone.
  def events
    redis.xrange(keys.attempts).map { |_id, fields| JSON.parse(fields["json"]) }
  end

  def events_of(type, unit_id: nil)
    events.select { |e| e["type"] == type && (unit_id.nil? || e["unit_id"] == unit_id) }
  end

  def meta = redis.hgetall(keys.meta)

  # Everything Redis reports about both unit streams and their consumer groups.
  def stream_snapshot
    [keys.units, keys.units_priority].to_h do |key|
      [key, { length: redis.xlen(key), stream: redis.xinfo(:stream, key), groups: redis.xinfo(:groups, key) }]
    end
  end

  describe "initialization fencing (deliverable 14)" do
    it "records init_failed once, refuses takeover, and report exits 3 showing the load error" do
      first = run_worker("spec-file-load-error", worker_id: "w1")
      expect(first.exit_code).to eq(2)
      expect(first.stderr).to include("failed to initialize").and include("broken_spec.rb raises at load time")

      second = run_worker("spec-file-load-error", worker_id: "w2")
      expect(second.exit_code).to eq(2)
      expect(second.stderr).to include("failed to initialize").and include("broken_spec.rb raises at load time")

      expect(meta["state"]).to eq("init_failed")
      expect(JSON.parse(meta["load_errors"]).join).to include("broken_spec.rb raises at load time")
      expect(redis.exists(keys.units, keys.units_priority, keys.unit_state)).to eq(0)
      expect(redis.exists(keys.exists)).to eq(1)
      expect(events_of("delivered")).to be_empty

      report = run_report
      expect(report.exit_code).to eq(3)
      expect(report.stdout).to include("init_failed").and include("broken_spec.rb raises at load time")
    end

    it "never reinitializes a build whose meta is gone while its tombstone remains" do
      expect(run_worker("all-pass", worker_id: "w1").exit_code).to eq(0)
      expect(redis.exists(keys.exists)).to eq(1)
      before = stream_snapshot

      redis.del(keys.meta)
      late = run_worker("all-pass", worker_id: "w2")

      expect(late.exit_code).to eq(2)
      expect(late.stderr).to include("build #{build} was previously initialized; its state is gone. " \
                                     "Choose a new build id")
      expect(redis.exists(keys.meta)).to eq(0)
      expect(stream_snapshot).to eq(before)
      expect(events_of("delivered").map { |e| e["worker_id"] }).not_to include("w2")
    end
  end

  describe "suite fingerprint (deliverable 15)" do
    it "rejects a worker with a different tag filter without reserving, and accepts a matching one" do
      initializer = run_worker("tag-filtered-selection", worker_id: "w1", extra_rspec_args: %w[--tag fast])
      expect(initializer.exit_code).to eq(0)
      expect(initializer.stdout).to include("initialized build #{build} (2 units, 3 examples)")
      manifest_fingerprint = meta.fetch("fingerprint")

      mismatch = run_worker("tag-filtered-selection", worker_id: "w2", extra_rspec_args: %w[--tag slow])
      expect(mismatch.exit_code).to eq(2)
      expect(mismatch.stderr).to match(/suite fingerprint mismatch: this worker computed [0-9a-f]{64} but the build/)
      expect(mismatch.stderr).to include("manifest records #{manifest_fingerprint}")
      expect(mismatch.stderr).not_to include("computed #{manifest_fingerprint}")
      expect(events_of("delivered").map { |e| e["worker_id"] }).not_to include("w2")
      expect(redis.hkeys(keys.workers)).not_to include("w2")

      matching = run_worker("tag-filtered-selection", worker_id: "w3", extra_rspec_args: %w[--tag fast])
      expect(matching.exit_code).to eq(0)
      expect(matching.stdout).to include("joined build #{build} (2 units, 3 examples)")
      expect(meta["finalized_count"]).to eq(meta["total_units"])
      expect(events_of("finalized").map { |e| e["unit_id"] }).to contain_exactly("./spec/fast_spec.rb",
                                                                                 "./spec/mixed_spec.rb")
      expect(events_of("worker_error").map { |e| e["worker_id"] }).to eq(["w2"])
    end

    it "rejects a worker whose checkout selects different example ids for identical arguments" do
      copy = Dir.mktmpdir("hopper-checkout")
      begin
        FileUtils.cp_r(File.join(HopperSpec::Fixtures.path("all-pass"), "."), copy)
        File.open(File.join(copy, "spec", "gamma_spec.rb"), "a") do |f|
          f.puts "\nRSpec.describe(\"delta\") { it(\"exists only in this checkout\") { expect(1).to eq(1) } }"
        end

        original = run_worker("all-pass", worker_id: "w1")
        expect(original.exit_code).to eq(0)
        expect(original.stdout).to include("(3 units, 7 examples)")

        other = HopperSpec::Fixtures.spawn(["work", "--build", build, "--worker", "w2", "--redis", redis_url],
                                           chdir: copy)
        other.wait(timeout: 30)
        expect(other.exit_code).to eq(2)
        expect(other.stderr).to match(/suite fingerprint mismatch: this worker computed [0-9a-f]{64} but the build/)
        expect(other.stderr).to include("manifest records #{meta.fetch("fingerprint")}")
        expect(other.stderr).to include("example_ids=8")
        expect(events_of("delivered").map { |e| e["worker_id"] }).not_to include("w2")
      ensure
        FileUtils.rm_rf(copy)
      end
    end
  end

  describe "expired builds (deliverable 16)" do
    it "reports 3 when only the tombstone remains and 2 when nothing remains" do
      expect(run_worker("all-pass").exit_code).to eq(0)

      redis.del(*keys.live, keys.leader)
      expect(HopperSpec::RedisHelper.keys(redis, build)).to eq([keys.exists])
      expired = run_report(args: %w[--init-timeout 1 --timeout 1])
      expect(expired.exit_code).to eq(3)
      expect(expired.stdout).to include("expired").and include("previously initialized; its state is gone")

      redis.del(keys.exists)
      missing = run_report(args: %w[--init-timeout 1 --timeout 1])
      expect(missing.exit_code).to eq(2)
      expect(missing.stdout).to include("never initialized")
    end

    it "makes a mid-run worker exit 2 when meta vanishes" do
      worker = spawn_worker("slow-but-legitimate", env: { "HOPPER_FIXTURE_SLEEP" => "2" })
      begin
        wait_until("the slow unit to be delivered") { events_of("delivered", unit_id: "./spec/slow_spec.rb").any? }
        redis.del(keys.meta)

        worker.wait(timeout: 20)
        expect(worker.exit_code).to eq(2)
        expect(worker.stderr).to include("state missing")
        expect(redis.exists(keys.meta)).to eq(0)
        expect(events_of("finalized", unit_id: "./spec/slow_spec.rb")).to be_empty
      ensure
        worker.terminate
      end
    end

    it "makes the next transition CORRUPT when unit_state vanishes, recording a redis worker_error" do
      worker = spawn_worker("slow-but-legitimate", env: { "HOPPER_FIXTURE_SLEEP" => "2" })
      begin
        wait_until("the slow unit to be delivered") { events_of("delivered", unit_id: "./spec/slow_spec.rb").any? }
        redis.del(keys.unit_state)

        worker.wait(timeout: 20)
        expect(worker.exit_code).to eq(2)
        expect(worker.stderr).to include("build #{build} is corrupt")
        expect(meta["state"]).to eq("ready")
        errors = events_of("worker_error")
        expect(errors.size).to eq(1)
        expect(errors.first).to include("phase" => "redis", "worker_id" => "w1", "unit_id" => "./spec/slow_spec.rb",
                                        "class" => "RSpec::Hopper::CorruptBuild")
        expect(errors.first["message"]).to include("state missing")
        expect(events_of("finalized", unit_id: "./spec/slow_spec.rb")).to be_empty
      ensure
        worker.terminate
      end
    end
  end

  describe "unsupported RSpec options (deliverable 17)" do
    it "rejects --fail-fast on the command line before initializing anything" do
      worker = run_worker("all-pass", extra_rspec_args: %w[--fail-fast])
      expect(worker.exit_code).to eq(2)
      expect(worker.stderr).to include("RSpec option --fail-fast is not supported by rspec-hopper")
      expect(HopperSpec::RedisHelper.keys(redis, build)).to be_empty
    end

    it "rejects --fail-fast coming from the project's .rspec" do
      worker = run_worker("fail-fast-in-rspec")
      expect(worker.exit_code).to eq(2)
      expect(worker.stderr).to include("RSpec option --fail-fast is not supported by rspec-hopper")
      expect(HopperSpec::RedisHelper.keys(redis, build)).to be_empty
    end
  end

  describe "requeue tolerance (deliverable 18)" do
    it "lets one flaky unit retry and finalizes the second as retry_budget_exhausted" do
      state_dir = HopperSpec::Fixtures.state_dir
      # 3 units * 0.3 = 0.9, so ceil allows exactly one unit to enter retry.
      worker = run_worker("two-flaky-units", args: %w[--max-requeues 2 --requeue-tolerance 0.3],
                                             env: { "HOPPER_FIXTURE_STATE_DIR" => state_dir })
      expect(worker.exit_code).to eq(0)
      expect(worker.stdout).to include("Retrying ./spec/flaky_a_spec.rb (retry 1 of 2; next attempt 2): 1 failure")

      requeued = events_of("requeued")
      expect(requeued.map { |e| e["unit_id"] }).to eq(["./spec/flaky_a_spec.rb"])
      expect(requeued.first).to include("retry_index" => 1, "reclaim_count" => 0, "ownership_generation" => 2)
      expect(events_of("finalized", unit_id: "./spec/flaky_a_spec.rb").map { |e| e["outcome"] }).to eq(["passed"])

      exhausted = events_of("finalized", unit_id: "./spec/flaky_b_spec.rb")
      expect(exhausted.size).to eq(1)
      expect(exhausted.first).to include("outcome" => "failed", "reason" => "retry_budget_exhausted",
                                         "retry_index" => 0, "ownership_generation" => 1)
      expect(events_of("finalized", unit_id: "./spec/stable_spec.rb").map { |e| e["outcome"] }).to eq(["passed"])
      expect(meta).to include("requeued_units_count" => "1", "finalized_count" => "3")

      summary_path = File.join(state_dir, "summary.json")
      report = run_report(args: ["--summary-out", summary_path])
      expect(report.exit_code).to eq(1)
      summary = JSON.parse(File.read(summary_path))
      expect(summary["flaky"]).to eq(["./spec/flaky_a_spec.rb"])
      expect(summary["failed"].map { |f| f.slice("unit_id", "reason") })
        .to eq([{ "unit_id" => "./spec/flaky_b_spec.rb", "reason" => "retry_budget_exhausted" }])
      expect(summary["retry_counts"]).to eq({ "./spec/flaky_a_spec.rb" => 1 })
    end
  end
end
