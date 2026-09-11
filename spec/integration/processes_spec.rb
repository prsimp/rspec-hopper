# frozen_string_literal: true

require "json"

# `--processes N`: both boot modes, per-child formatter output, a SIGKILLed
# child, and the parent's exit-code precedence, all through real
# `rspec-hopper work` processes against the test Redis.
RSpec.describe "--processes N", :integration, :redis do
  let(:redis_url) { HopperSpec::RedisHelper.url }
  let(:redis) { HopperSpec::RedisHelper.new_connection }
  let(:build) { HopperSpec::RedisHelper.build_id("procs") }
  let(:keys) { RSpec::Hopper::Keys.new(build) }
  let(:state_dir) { HopperSpec::Fixtures.state_dir }

  after do
    HopperSpec::RedisHelper.delete_build(redis, build)
    redis.close
  end

  def spawn_parent(fixture, args: [], env: {}, extra_rspec_args: [])
    HopperSpec::Fixtures.spawn_worker(
      fixture: fixture, build_id: build, worker_id: "w", redis_url: redis_url,
      args: ["--processes", "2", *args], env: { "HOPPER_FIXTURE_STATE_DIR" => state_dir }.merge(env),
      extra_rspec_args: extra_rspec_args
    )
  end

  def run_parent(fixture, timeout: 30, **spawn_kwargs)
    parent = spawn_parent(fixture, **spawn_kwargs)
    parent.wait(timeout: timeout)
    parent
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

  def events
    redis.xrange(keys.attempts).map { |_id, fields| JSON.parse(fields["json"]) }
  end

  def events_of(type, unit_id: nil)
    events.select { |e| e["type"] == type && (unit_id.nil? || e["unit_id"] == unit_id) }
  end

  def workers = redis.hgetall(keys.workers).transform_values { |v| JSON.parse(v) }

  # The JSON lines the test-env-number style fixtures append to env-<pid>.
  def env_records
    Dir[File.join(state_dir, "env-*")].flat_map do |path|
      File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
    end
  end

  # Child pids as the parent logged them: "started w.2 (pid 123, ...)".
  def child_pids(parent)
    parent.stderr.scan(/started (w\.\d+) \(pid (\d+),/).to_h { |worker_id, pid| [worker_id, pid.to_i] }
  end

  describe "boot modes" do
    it "runs all-pass with two per-process children and exits 0" do
      parent = run_parent("all-pass")
      expect(parent.exit_code).to eq(0)
      expect(parent.stderr).to include("started w.1 (pid").and include("started w.2 (pid")
      expect(parent.stderr).to include("w.1 (pid").and include("exited 0")
      expect(workers.keys).to contain_exactly("w.1", "w.2")
      expect(workers.values.sum { |w| w["processed"] }).to eq(3)
      expect(events_of("finalized").map { |e| e["outcome"] }).to eq(%w[passed passed passed])
      expect(run_report.exit_code).to eq(0)
    end

    it "gives each per-process child the same TEST_ENV_NUMBER at load time and run time" do
      parent = run_parent("test-env-number")
      expect(parent.exit_code).to eq(0)

      records = env_records
      expect(records.map { |r| r["file"] }).to contain_exactly("env_a_spec.rb", "env_b_spec.rb")
      records.each do |record|
        expect(record["load"]).to eq(record["run"])
        expect(record["run"]).to eq("").or eq("2")
      end
      expect(run_report.exit_code).to eq(0)
    end

    it "shares one boot and lets after_fork re-derive the value in each child" do
      parent = run_parent("shared-boot-hook", args: %w[--boot shared])
      expect(parent.exit_code).to eq(0)

      records = env_records
      expect(records.map { |r| r["file"] }).to contain_exactly("env_a_spec.rb", "env_b_spec.rb")
      records.each do |record|
        expect(record["load"]).to eq("<unset>") # the suite was loaded once in the parent
        expect(record["derived"]).to eq(record["run"])
        expect(record["run"]).to eq("").or eq("2")
      end
      expect(workers.keys).to all(match(/\Aw\.[12]\z/))
      expect(run_report.exit_code).to eq(0)
    end

    it "refuses --boot shared when no after_fork hook is registered" do
      parent = run_parent("test-env-number", args: %w[--boot shared])
      expect(parent.exit_code).to eq(2)
      expect(parent.stderr).to include("--boot shared needs at least one RSpec::Hopper.after_fork hook")
      expect(parent.stderr).not_to include("started w.1")
      expect(HopperSpec::RedisHelper.keys(redis, build)).to be_empty
      expect(env_records).to be_empty
    end
  end

  describe "per-child formatter output" do
    it "substitutes the child number placeholder in --out so each child writes its own file" do
      placeholder = RSpec::Hopper::CLI::FormatterArgs::PLACEHOLDER
      out = File.join(state_dir, "out-#{placeholder}.json")
      parent = run_parent("all-pass", extra_rspec_args: ["--format", "json", "--out", out])
      expect(parent.exit_code).to eq(0)

      paths = %w[out-.json out-2.json].map { |name| File.join(state_dir, name) }
      expect(paths).to all(satisfy { |path| File.exist?(path) })
      outputs = paths.map { |path| JSON.parse(File.read(path)) }
      expect(outputs).to all(include("examples", "summary"))

      # Which child ran which unit is a race; together they ran every example exactly once.
      ids = outputs.flat_map { |o| o["examples"].map { |e| e["id"] } }
      expect(ids.size).to eq(7)
      expect(ids.uniq.size).to eq(7)
      expect(ids.map { |id| id[/\A(.*)\[/, 1] }.uniq)
        .to contain_exactly("./spec/alpha_spec.rb", "./spec/beta_spec.rb", "./spec/gamma_spec.rb")
      expect(outputs.sum { |o| o["summary"]["example_count"] }).to eq(7)
      expect(outputs.sum { |o| o["summary"]["failure_count"] }).to eq(0)
    end
  end

  describe "a SIGKILLed child" do
    it "loses its unit to the sibling and the build still completes" do
      parent = spawn_parent("slow-but-legitimate", args: %w[--timeout 2], env: { "HOPPER_FIXTURE_SLEEP" => "3" })
      begin
        holder = wait_until("a child to hold the slow unit") do
          workers.find { |_id, w| w["current_unit"] == "./spec/slow_spec.rb" }&.first
        end
        pid = wait_until("the parent to log #{holder}'s pid") { child_pids(parent)[holder] }
        Process.kill("KILL", pid)

        parent.wait(timeout: 30)
        # A signal-killed child has no exit status; the supervisor treats that
        # as an infrastructure failure, so the parent exits 2 (not 0).
        expect(parent.exit_code).to eq(2)
        expect(parent.stderr).to include("#{holder} (pid #{pid}) killed by SIGKILL")

        sibling = (%w[w.1 w.2] - [holder]).first
        reclaimed = events_of("reclaimed", unit_id: "./spec/slow_spec.rb")
        expect(reclaimed.size).to eq(1)
        expect(reclaimed.first).to include("worker_id" => sibling, "previous_worker_id" => holder, "reclaim_count" => 1,
                                           "retry_index" => 0, "ownership_generation" => 2)
        finalized = events_of("finalized", unit_id: "./spec/slow_spec.rb")
        expect(finalized.size).to eq(1)
        expect(finalized.first).to include("worker_id" => sibling, "outcome" => "passed")
        expect(events_of("requeued")).to be_empty
        expect(redis.hget(keys.meta, "finalized_count")).to eq("2")

        report = run_report
        expect(report.exit_code).to eq(0)
        expect(report.stdout).to include("passed")
      ensure
        parent.terminate
      end
    end
  end

  describe "exit-code precedence" do
    let(:hang_args) { %w[--max-unit-duration 1 --timeout 1 --max-reclaims 0] }

    def expect_hung_unit_finalized_by_sibling
      expect(events_of("abandoned", unit_id: "./spec/hang_spec.rb").size).to eq(1)
      finalized = events_of("finalized", unit_id: "./spec/hang_spec.rb")
      expect(finalized.size).to eq(1)
      expect(finalized.first).to include("outcome" => "failed", "reason" => "reclaim_budget_exhausted")
      expect(redis.hget(keys.meta, "finalized_count")).to eq("2")
    end

    it "is 4 without --report-on-exit when one child aborted a hung unit and the other exited 0" do
      parent = run_parent("hangs-forever", args: hang_args)
      expect(parent.exit_code).to eq(4)
      expect(parent.stderr).to include("Aborting worker: ./spec/hang_spec.rb exceeded 1s")
      expect(parent.stderr).to include("exited 4").and include("exited 0")
      expect(parent.stdout).not_to include("rspec-hopper report:")
      expect_hung_unit_finalized_by_sibling
      expect(run_report.exit_code).to eq(1)
    end

    it "is the report's code with --report-on-exit, so a child's 4 is diagnostic only" do
      parent = run_parent("hangs-forever", args: [*hang_args, "--report-on-exit"])
      expect(parent.exit_code).to eq(1)
      expect(parent.stderr).to include("exited 4").and include("the verdict comes from report")
      expect(parent.stdout).to include("rspec-hopper report: build #{build}: failed")
      expect(parent.stdout).to include("failed: ./spec/hang_spec.rb (reclaim_budget_exhausted")
      expect(parent.stdout).to include("abandoned (exceeded --max-unit-duration): ./spec/hang_spec.rb")
      expect_hung_unit_finalized_by_sibling
    end

    it "is 2 when any child exited 2, without --report-on-exit" do
      parent = run_parent("fail-fast-in-rspec")
      expect(parent.exit_code).to eq(2)
      expect(parent.stderr).to include("RSpec option --fail-fast is not supported")
      expect(parent.stderr.scan("exited 2").size).to eq(2)
      expect(HopperSpec::RedisHelper.keys(redis, build)).to be_empty
    end

    it "is 2 when any child exited 2 even with --report-on-exit, and the report does not run" do
      parent = run_parent("fail-fast-in-rspec", args: %w[--report-on-exit])
      expect(parent.exit_code).to eq(2)
      expect(parent.stderr.scan("exited 2").size).to eq(2)
      expect(parent.stdout).not_to include("rspec-hopper report:")
      expect(HopperSpec::RedisHelper.keys(redis, build)).to be_empty
    end
  end
end
