# frozen_string_literal: true

require "json"
require "redis"

RSpec.describe RSpec::Hopper::Worker do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:clock) { HopperSpec::FakeClock.new }
  let(:queue) { HopperSpec::FakeQueue.new(build_id: "build-1", max_requeues: 2, requeue_tolerance: 1.0, clock: clock) }
  let(:config) { work_config(max_requeues: 2, requeue_tolerance: 1.0, revision: "rev1") }
  let(:sleeper) { ->(seconds) { clock.advance(seconds) } }

  let(:passing_files) do
    { "spec/a_spec.rb" => HopperSpec::RSpecSandbox::PASSING_SPEC,
      "spec/b_spec.rb" => "RSpec.describe('b') { it('solo') { expect(:b).to eq(:b) } }\n" }
  end

  # Loads the suite in a temporary project, yields it for build seeding, then
  # runs a worker against the fake queue.
  def run_worker(files, args: [], config: self.config, dot_rspec: nil, **worker_opts)
    with_project(files, dot_rspec: dot_rspec) do
      suite = load_suite(args, config: config, out: out, err: err)
      spy = HopperSpec::RSpecSandbox::ReporterSpy.new.attach(suite.configuration.reporter)
      yield suite if block_given?
      worker = described_class.new(config: config, queue_factory: -> { queue }, suite: suite, out: out, err: err,
                                   clock: clock, sleeper: sleeper, **worker_opts)
      HopperSpec::RSpecSandbox::WorkerRun.new(code: worker.run, suite: suite, spy: spy,
                                              configuration: suite.configuration)
    end
  end

  def finalized(unit_id) = queue.events_of("finalized").select { |e| e["unit_id"] == unit_id }

  describe "initialization" do
    it "elects itself leader and publishes a manifest built from the suite" do
      result = run_worker(passing_files)
      expect(result.code).to eq(0)
      expect(queue.status).to be_ready
      manifest = queue.manifest
      expect(manifest).to have_attributes(total_units: 2, total_examples: 3, file_args: ["spec"], revision: "rev1",
                                          load_errors: [], fingerprint: result.suite.fingerprint.value,
                                          seed: result.configuration.seed)
      expect(manifest.file_counts).to eq("./spec/a_spec.rb" => 2, "./spec/b_spec.rb" => 1)
      expect(manifest.ready_at).to be_a(Integer)
      expect(out.string).to include("[hopper w1] initialized build build-1 (2 units, 3 examples)")
      expect(queue.unit_states.keys).to eq(manifest.unit_ids)
    end

    it "joins an existing build as a follower and adopts its seed before running" do
      strategy = nil
      result = run_worker(passing_files) do |suite|
        strategy = suite.configuration.ordering_registry.fetch(:global)
        queue.seed_ready!(suite.to_manifest.with(seed: 4242))
      end
      expect(result.code).to eq(0)
      expect(out.string).to include("[hopper w1] joined build build-1 (2 units, 3 examples)")
      expect(result.configuration.seed).to eq(4242)
      expect(result.configuration.ordering_registry.fetch(:global)).to equal(strategy)
      expect(queue.events_of("finalized").map { |e| e["worker_id"] }).to all(eq("w1"))
    end

    it "polls every 0.5s while another worker holds the lease, then joins" do
      sleeps = []
      manifest = nil
      polling = lambda do |seconds|
        sleeps << seconds
        clock.advance(seconds)
        queue.seed_ready!(manifest) if sleeps.size == 3
      end
      result = run_worker(passing_files, sleeper: polling) do |suite|
        manifest = suite.to_manifest.with(seed: 7)
        queue.acquire_leader("other")
      end
      expect(result.code).to eq(0)
      expect(sleeps).to eq([0.5, 0.5, 0.5])
      expect(out.string).to include("joined build build-1")
    end

    it "takes over initialization when the lease expires before publication" do
      sleeps = 0
      expiring = lambda do |seconds|
        clock.advance(seconds)
        queue.expire_leader! if (sleeps += 1) == 2
      end
      result = run_worker(passing_files, sleeper: expiring) { queue.acquire_leader("dead-initializer") }
      expect(result.code).to eq(0)
      expect(out.string).to include("initialized build build-1")
    end

    it "exits 2 with 'build never initialized' when init_timeout elapses" do
      result = run_worker(passing_files, config: config.with(init_timeout: 2)) { queue.acquire_leader("other") }
      expect(result.code).to eq(2)
      expect(err.string).to include("[hopper w1] build never initialized")
      expect(queue.events_of("worker_error").first).to include("phase" => "init", "worker_id" => "w1")
      expect(queue.events_of("delivered")).to be_empty
    end

    it "publishes init_failed with the load errors and exits 2 when spec files fail to load" do
      files = passing_files.merge("spec/bad_spec.rb" => "RSpec.describe('bad') { raise 'kaboom at load' }\n")
      result = run_worker(files)
      expect(result.code).to eq(2)
      expect(queue.status).to be_init_failed
      expect(queue.manifest.load_errors.join).to include("kaboom at load")
      expect(err.string).to include("failed to initialize; spec files could not be loaded:")
        .and include("An error occurred while loading ./spec/bad_spec.rb").and include("kaboom at load")
      expect(queue.events_of("delivered")).to be_empty
    end

    it "prints the recorded errors and exits 2 when joining an init_failed build" do
      result = run_worker(passing_files) do |suite|
        queue.seed_init_failed!(suite.to_manifest.with(load_errors: ["boom at load"]))
      end
      expect(result.code).to eq(2)
      expect(err.string).to include("boom at load")
      expect(queue.leader).to be_nil
    end

    it "exits 2 when the build id was previously initialized and its state is gone" do
      result = run_worker(passing_files) { queue.tombstone_only! }
      expect(result.code).to eq(2)
      expect(err.string)
        .to include("[hopper w1] build build-1 was previously initialized; its state is gone. Choose a new build id.")
      expect(queue.meta).to be_nil
    end

    it "exits 2 on a fingerprint mismatch without reserving anything" do
      result = run_worker(passing_files) { |suite| queue.seed_ready!(suite.to_manifest.with(fingerprint: "f" * 64)) }
      expect(result.code).to eq(2)
      expect(err.string).to include("suite fingerprint mismatch").and include("f" * 64)
        .and include(result.suite.fingerprint.value)
      expect(queue.events_of("delivered")).to be_empty
      expect(queue.events_of("worker_error").first["class"]).to eq("RSpec::Hopper::FingerprintMismatch")
    end

    it "rejects unsupported RSpec options before opening the queue" do
      opened = false
      with_project(passing_files) do
        worker = described_class.new(config: config.with(rspec_args: ["--fail-fast"]),
                                     queue_factory: -> { opened = true }, out: out, err: err)
        expect(worker.run).to eq(2)
      end
      expect(err.string).to include("[hopper w1] RSpec option --fail-fast is not supported")
      expect(opened).to be(false)
    end

    it "exits 2 when Redis is unreachable" do
      with_project(passing_files) do
        suite = load_suite([], config: config, out: out, err: err)
        worker = described_class.new(config: config, suite: suite, out: out, err: err,
                                     queue_factory: -> { raise Redis::CannotConnectError, "nope" })
        expect(worker.run).to eq(2)
      end
      expect(err.string).to include("Redis unreachable: Redis::CannotConnectError: nope")
    end

    it "loads the suite itself when none is given and applies formatter pairs to a preloaded one" do
      with_project(passing_files) do |dir|
        worker = described_class.new(config: config, queue_factory: -> { queue }, out: out, err: err, clock: clock,
                                     sleeper: sleeper)
        expect(worker.run).to eq(0)
        expect(worker.suite.unit_ids).to eq(%w[./spec/a_spec.rb ./spec/b_spec.rb])
        expect(File).not_to exist(File.join(dir, "tmp/out.json"))
      end
      json_config = config.with(rspec_args: ["--format", "json", "--out", "tmp/out.json", "spec"])
      other_queue = HopperSpec::FakeQueue.new(clock: clock)
      with_project(passing_files) do |dir|
        suite = load_suite([], config: config, out: out, err: err)
        worker = described_class.new(config: json_config, queue_factory: -> { other_queue }, suite: suite, out: out,
                                     err: err, clock: clock, sleeper: sleeper)
        expect(worker.run).to eq(0)
        report = JSON.parse(File.read(File.join(dir, "tmp/out.json")))
        expect(report["examples"].size).to eq(3)
        expect(report["summary"]).to include("example_count" => 3, "failure_count" => 0)
      end
    end
  end

  describe "the loop" do
    it "finalizes every unit, then exits 0 on completion with the reporter started and finished once" do
      result = run_worker(passing_files)
      expect(result.code).to eq(0)
      expect(queue).to be_complete
      expect(queue.events.map { |e| e["type"] }).to eq(%w[delivered finalized delivered finalized])
      expect(queue.events_of("finalized").map { |e| e["outcome"] }).to all(eq("passed"))
      expect(result.spy.count(:start)).to eq(1)
      expect(result.spy.count(:dump_summary)).to eq(1)
      expect(result.spy.count(:close)).to eq(1)
      expect(result.spy.count(:example_passed)).to eq(3)
      expect(out.string).to include("3 examples, 0 failures")
      expect(queue.workers["w1"]).to include("processed" => 2)
    end

    it "retries a fails-first-passes-second unit in the same process and reports it once as passed" do
      files = passing_files.merge("spec/flaky_spec.rb" => HopperSpec::RSpecSandbox.flaky_spec)
      # The fixture itself asserts on its second attempt that the marker holds
      # this process's pid, so a pass here proves both attempts ran in one process.
      result = run_worker(files)
      expect(result.code).to eq(0)
      expect(queue.events_of("requeued").map { |e| e.slice("unit_id", "retry_index", "failure_summary") })
        .to eq([{ "unit_id" => "./spec/flaky_spec.rb", "retry_index" => 1, "failure_summary" => "1 failure" }])
      expect(finalized("./spec/flaky_spec.rb")).to contain_exactly(include("outcome" => "passed", "retry_index" => 1,
                                                                           "ownership_generation" => 2))
      expect(out.string)
        .to include("[hopper w1] Retrying ./spec/flaky_spec.rb (retry 1 of 2; next attempt 2): 1 failure")
      expect(result.spy.times_seen("./spec/flaky_spec.rb[1:1]")).to eq(1)
      expect(result.spy.count(:example_started)).to eq(5)
      expect(result.spy.count(:example_failed)).to eq(0)
      expect(out.string).to include("5 examples, 0 failures")
    end

    it "finalizes a retry-budget-exhausted attempt as failed and replays it" do
      zero = HopperSpec::FakeQueue.new(max_requeues: 0, clock: clock)
      files = { "spec/flaky_spec.rb" => HopperSpec::RSpecSandbox.flaky_spec }
      result = nil
      with_project(files) do
        suite = load_suite([], config: config, out: out, err: err)
        result = described_class.new(config: config, queue_factory: -> { zero }, suite: suite, out: out, err: err,
                                     clock: clock, sleeper: sleeper).run
      end
      expect(result).to eq(0)
      expect(zero.events_of("requeued")).to be_empty
      expect(zero.events_of("finalized").first).to include("outcome" => "failed", "reason" => "retry_budget_exhausted")
      expect(out.string).to include("2 examples, 1 failure").and include("first attempt fails")
    end

    it "finalizes a unit as test_failure when a SystemExit escapes an example, and keeps working" do
      files = passing_files.merge("spec/mixed_spec.rb" => <<~RUBY)
        RSpec.describe "mixed" do
          it("raises") { raise "plain failure" }
          it("exits") { exit 3 }
          it("never runs") { expect(1).to eq(1) }
        end
      RUBY
      result = run_worker(files, args: ["--order", "defined"])
      expect(result.code).to eq(0)
      expect(queue).to be_complete
      expect(queue.events_of("requeued")).to be_empty
      event = finalized("./spec/mixed_spec.rb").first
      expect(event).to include("outcome" => "failed", "reason" => "test_failure")
      expect(event["errors"].map { |e| e["class"] }).to eq(%w[RuntimeError SystemExit])
      expect(event["errors"].last).to include("example_id" => "./spec/mixed_spec.rb[1:2]")
      expect(err.string).to include("SystemExit escaped an example in ./spec/mixed_spec.rb")
      expect(result.spy.count(:example_failed)).to eq(1)
      expect(result.spy.times_seen("./spec/mixed_spec.rb[1:2]")).to eq(1)
      expect(queue.events_of("finalized").size).to eq(3)
    end

    it "keeps the process alive when an Interrupt escapes an example" do
      files = { "spec/int_spec.rb" => "RSpec.describe('int') { it('interrupts') { raise Interrupt } }\n" }
      result = run_worker(files)
      expect(result.code).to eq(0)
      expect(finalized("./spec/int_spec.rb").first["errors"].first).to include("class" => "Interrupt")
    end

    it "discards a stale result and records stale_rejected" do
      files = { "spec/stale_spec.rb" => <<~RUBY }
        RSpec.describe "stale" do
          it("runs while ownership moves") { HopperSpec::FixtureHooks.fire(:during) }
        end
      RUBY
      result = run_worker(files) do
        HopperSpec::FixtureHooks.on(:during) do
          other = queue.simulate_reclaim("./spec/stale_spec.rb", by: "w2")
          queue.finalize(other, outcome: :passed, duration_ms: 1)
        end
      end
      expect(result.code).to eq(0)
      expect(queue.events_of("stale_rejected")).to contain_exactly(include("unit_id" => "./spec/stale_spec.rb",
                                                                           "worker_id" => "w1",
                                                                           "operation" => "finalize"))
      expect(finalized("./spec/stale_spec.rb").map { |e| e["worker_id"] }).to eq(["w2"])
      expect(result.spy.count(:example_started)).to eq(0)
      expect(out.string).to include("reservation for ./spec/stale_spec.rb is stale; result discarded")
    end

    it "runs before(:suite) once per process, not once per unit" do
      files = passing_files.merge("spec/hooked_spec.rb" => <<~RUBY)
        RSpec.configure { |c| c.before(:suite) { HopperSpec::FixtureHooks.fire(:before_suite) } }
        RSpec.describe("hooked") { it("x") { expect(1).to eq(1) } }
      RUBY
      runs = 0
      result = run_worker(files) { HopperSpec::FixtureHooks.on(:before_suite) { runs += 1 } }
      expect(result.code).to eq(0)
      expect(queue.events_of("finalized").size).to eq(3)
      expect(runs).to eq(1)
    end

    it "exits 2 when a before(:suite) hook fails instead of finalizing units it never ran" do
      files = passing_files.merge("spec/hooked_spec.rb" => <<~RUBY)
        RSpec.configure { |c| c.before(:suite) { raise "suite hook boom" } }
        RSpec.describe("hooked") { it("x") { expect(1).to eq(1) } }
      RUBY
      result = run_worker(files)
      expect(result.code).to eq(2)
      expect(queue.events_of("finalized")).to be_empty
      expect(queue.events_of("worker_error").first).to include("phase" => "execution")
    end

    it "reclaims lost units before reserving new ones" do
      other = HopperSpec::FakeQueue.new(clock: clock)
      result = nil
      with_project(passing_files) do
        suite = load_suite([], config: config, out: out, err: err)
        other.seed_ready!(suite.to_manifest)
        other.reserve("dead")
        other.make_reclaimable!("./spec/a_spec.rb")
        result = described_class.new(config: config, queue_factory: -> { other }, suite: suite, out: out, err: err,
                                     clock: clock, sleeper: sleeper).run
      end
      expect(result).to eq(0)
      expect(other.events_of("reclaimed").first).to include("unit_id" => "./spec/a_spec.rb", "worker_id" => "w1",
                                                            "previous_worker_id" => "dead")
      expect(other.events_of("finalized").first).to include("unit_id" => "./spec/a_spec.rb", "reclaim_count" => 1)
    end

    it "exits 2 when the parent is gone (supervised)" do
      pids = [100, 999]
      result = run_worker(passing_files, config: config.with(supervised: true), ppid: -> { pids.shift || 999 })
      expect(result.code).to eq(2)
      expect(err.string).to include("[hopper w1] parent gone")
      expect(queue.events_of("finalized").size).to eq(1)
    end
  end

  describe "build state failures" do
    it "exits 2 when meta vanishes after ready instead of treating the empty queue as done" do
      vanishing = Class.new(HopperSpec::FakeQueue) do
        def finalize(*args, **kwargs)
          super.tap { vanish_meta! }
        end
      end.new(clock: clock)
      result = nil
      with_project(passing_files) do
        suite = load_suite([], config: config, out: out, err: err)
        result = described_class.new(config: config, queue_factory: -> { vanishing }, suite: suite, out: out,
                                     err: err, clock: clock, sleeper: sleeper).run
      end
      expect(result).to eq(2)
      expect(err.string).to include("[hopper w1] build state for build-1 is gone")
      expect(vanishing.events_of("worker_error").first).to include("phase" => "redis",
                                                                   "class" => "RSpec::Hopper::BuildStateMissing")
    end

    it "records a worker_error with phase redis and exits 2 on CorruptBuild" do
      result = run_worker(passing_files) do |suite|
        queue.seed_ready!(suite.to_manifest)
        queue.corrupt_unit_state!("./spec/a_spec.rb")
      end
      expect(result.code).to eq(2)
      expect(err.string).to include("build build-1 is corrupt")
      expect(queue.events_of("worker_error").first).to include("phase" => "redis",
                                                               "class" => "RSpec::Hopper::CorruptBuild")
      expect(queue.events_of("finalized")).to be_empty
    end
  end
end
