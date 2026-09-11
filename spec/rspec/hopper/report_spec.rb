# frozen_string_literal: true

RSpec.describe RSpec::Hopper::Report do
  # A queue whose answers are scripted per poll. Each sequence yields its next
  # value on every call and repeats its last value once exhausted; an Exception
  # instance in a sequence is raised instead of returned.
  let(:fake_queue_class) do
    Class.new do
      attr_reader :calls

      def initialize(statuses:, finalized: [0], workers: [{}], events: [])
        @statuses = statuses
        @finalized = finalized
        @workers = workers
        @events = events
        @calls = Hash.new(0)
      end

      def status = step(:status, @statuses)
      def finalized_count = step(:finalized_count, @finalized)
      def workers = step(:workers, @workers)

      def attempt_events
        @calls[:attempt_events] += 1
        @events
      end

      def manifest
        meta = @statuses.last.meta
        meta && RSpec::Hopper::Manifest.from_meta(meta)
      end

      def total_units = manifest.total_units
      def complete? = finalized_count == total_units

      private

      def step(name, sequence)
        index = @calls[name]
        @calls[name] += 1
        value = sequence[[index, sequence.size - 1].min]
        raise value if value.is_a?(Exception)

        value
      end
    end
  end

  # Both clocks advance together whenever the report sleeps.
  let(:fake_clocks_class) do
    Class.new do
      attr_reader :slept

      def initialize(wall_ms:)
        @mono = 1000.0
        @wall_ms = wall_ms
        @slept = []
      end

      def clock = -> { @mono }
      def wall_clock = -> { @wall_ms }

      def sleeper
        lambda do |seconds|
          @slept << seconds
          @mono += seconds
          @wall_ms += (seconds * 1000).to_i
        end
      end
    end
  end
  let(:build_id) { "build-42" }
  let(:ready_at) { 1_700_000_000_000 }
  let(:now_ms) { ready_at + 5_000 }
  let(:unit_ids) { ["./spec/a_spec.rb", "./spec/b_spec.rb", "./spec/c_spec.rb"] }
  let(:file_args) { %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb] }
  let(:manifest) do
    RSpec::Hopper::Manifest.new(
      total_examples: 30, file_counts: unit_ids.to_h { |id| [id, 10] }, file_args: file_args,
      fingerprint: "fp", seed: 1234, ready_at: ready_at, revision: "abc"
    )
  end
  let(:meta) { manifest.to_meta.merge("state" => "ready", "finalized_count" => "0", "requeued_units_count" => "0") }
  let(:ready) { status_of(state: "ready", tombstone: true, meta: meta) }
  let(:absent) { status_of(state: nil, tombstone: false, meta: nil) }
  let(:tombstone_only) { status_of(state: nil, tombstone: true, meta: nil) }
  let(:live_workers) { { "w1" => { "last_seen" => now_ms - 1_000, "current_unit" => nil, "processed" => 3 } } }
  let(:config_overrides) { {} }
  let(:config) do
    RSpec::Hopper::ReportConfig.build(
      build_id: build_id, redis_url: "redis://x", timeout: 60, init_timeout: 10, inactive_timeout: 20,
      **config_overrides
    )
  end
  let(:clocks) { fake_clocks_class.new(wall_ms: now_ms) }
  let(:out) { StringIO.new }

  def status_of(state:, tombstone:, meta:)
    RSpec::Hopper::Queue::Status.new(state: state, tombstone: tombstone, meta: meta)
  end

  def event(type, unit_id:, worker_id:, retry_index: 0, reclaim_count: 0, **extra)
    { "type" => type, "unit_id" => unit_id, "worker_id" => worker_id, "retry_index" => retry_index,
      "reclaim_count" => reclaim_count, "ownership_generation" => 1 + retry_index + reclaim_count,
      "at_ms" => ready_at + 1 }.merge(extra.transform_keys(&:to_s))
  end

  def passed(unit_id, worker_id: "w1", **extra)
    event("finalized", unit_id: unit_id, worker_id: worker_id, outcome: "passed", duration_ms: 5, **extra)
  end

  def all_passed_events
    unit_ids.flat_map { |id| [event("delivered", unit_id: id, worker_id: "w1"), passed(id)] }
  end

  def report_for(queue, **opts)
    described_class.new(config: config, queue: queue, clock: clocks.clock, sleeper: clocks.sleeper,
                        wall_clock: clocks.wall_clock, poll_interval: 1.0, **opts)
  end

  describe "initialization wait" do
    it "exits 2 with verdict missing when neither manifest nor tombstone appears within --init-timeout" do
      queue = fake_queue_class.new(statuses: [absent])
      report = report_for(queue)

      expect(report.run(out: out)).to eq(2)
      expect(out.string).to include("build build-42 never initialized")
      expect(report.summary).to include("verdict" => "missing", "exit_code" => 2, "state" => nil,
                                        "total_units" => nil, "failed" => [], "never_finalized" => [])
      expect(clocks.slept.sum).to be >= 10
      expect(queue.calls[:status]).to be > 1
    end

    it "keeps polling through absent statuses until the manifest appears" do
      queue = fake_queue_class.new(statuses: [absent, absent, ready], finalized: [3], workers: [live_workers],
                                   events: all_passed_events)
      report = report_for(queue)

      expect(report.run(out: out)).to eq(0)
      expect(queue.calls[:status]).to eq(3)
      expect(clocks.slept).to eq([1.0, 1.0])
    end

    it "exits 3 with verdict expired when only the tombstone exists" do
      queue = fake_queue_class.new(statuses: [absent, tombstone_only])
      report = report_for(queue)

      expect(report.run(out: out)).to eq(3)
      expect(out.string).to include("previously initialized; its state is gone")
      expect(report.summary).to include("verdict" => "expired", "exit_code" => 3)
    end
  end

  describe "init_failed" do
    let(:failed_manifest) do
      RSpec::Hopper::Manifest.new(total_examples: 0, file_counts: {}, file_args: file_args, fingerprint: nil,
                                  seed: nil, ready_at: ready_at,
                                  load_errors: ["spec/a_spec.rb:3: NameError: uninitialized constant Foo"])
    end
    let(:init_failed) do
      status_of(state: "init_failed", tombstone: true,
                meta: failed_manifest.to_meta.merge("state" => "init_failed"))
    end

    it "prints the recorded load errors and exits 3" do
      queue = fake_queue_class.new(statuses: [init_failed])
      report = report_for(queue)

      expect(report.run(out: out)).to eq(3)
      expect(out.string).to include("failed to initialize")
      expect(out.string).to include("NameError: uninitialized constant Foo")
      expect(report.summary).to include("verdict" => "init_failed", "state" => "init_failed", "exit_code" => 3,
                                        "load_errors" => failed_manifest.load_errors)
      expect(queue.calls[:finalized_count]).to eq(0)
    end
  end

  describe "completion" do
    it "waits until finalized_count reaches total_units then exits 0 on an all-pass log" do
      queue = fake_queue_class.new(statuses: [ready], finalized: [0, 1, 3], workers: [live_workers],
                                   events: all_passed_events)
      report = report_for(queue)

      expect(report.run(out: out)).to eq(0)
      expect(out.string).to include("build-42: passed")
      expect(out.string).to include("units: 3 total, 3 finalized; examples: 30 selected")
      expect(clocks.slept).to eq([1.0, 1.0])
      expect(report.summary).to include("verdict" => "passed", "exit_code" => 0, "state" => "ready",
                                        "finalized_count" => 3, "total_units" => 3, "total_examples" => 30)
    end

    it "exits 1 and lists failed units with reason and first error message" do
      errors = [{ "example_id" => "./spec/b_spec.rb[1:1]", "class" => "RuntimeError",
                  "message" => "boom\n  more detail" }]
      events = [
        event("delivered", unit_id: unit_ids[0], worker_id: "w1"), passed(unit_ids[0]),
        event("delivered", unit_id: unit_ids[1], worker_id: "w2"),
        event("finalized", unit_id: unit_ids[1], worker_id: "w2", outcome: "failed", reason: "test_failure",
                           duration_ms: 9, errors: errors),
        event("delivered", unit_id: unit_ids[2], worker_id: "w1"), passed(unit_ids[2])
      ]
      queue = fake_queue_class.new(statuses: [ready], finalized: [3], workers: [live_workers], events: events)
      report = report_for(queue)

      expect(report.run(out: out)).to eq(1)
      expect(out.string).to include("build-42: failed")
      expect(out.string).to include("1 of 3 units failed")
      expect(out.string).to include("failed: ./spec/b_spec.rb (test_failure, worker w2) RuntimeError: boom")
      expect(report.summary["failed"]).to eq([
                                               { "unit_id" => "./spec/b_spec.rb", "reason" => "test_failure",
                                                 "worker_id" => "w2", "errors" => errors }
                                             ])
    end

    it "exits 1 for zero selected examples by default, naming the file inputs" do
      twelve = (1..12).map { |i| "spec/f#{i}" }
      empty = RSpec::Hopper::Manifest.new(total_examples: 0, file_counts: {}, file_args: twelve,
                                          fingerprint: "fp", seed: 1, ready_at: ready_at)
      status = status_of(state: "ready", tombstone: true, meta: empty.to_meta.merge("state" => "ready"))
      queue = fake_queue_class.new(statuses: [status], finalized: [0], workers: [{}])
      report = report_for(queue)

      expect(report.run(out: out)).to eq(1)
      expect(out.string).to include("12 files given, 0 examples selected")
      expect(out.string).to include("spec/f12")
      expect(report.summary).to include("verdict" => "failed", "exit_code" => 1, "total_examples" => 0,
                                        "file_args" => empty.file_args)
    end

    context "with --allow-empty" do
      let(:config_overrides) { { allow_empty: true } }

      it "passes a zero-example build" do
        empty = RSpec::Hopper::Manifest.new(total_examples: 0, file_counts: {}, file_args: %w[spec],
                                            fingerprint: "fp", seed: 1, ready_at: ready_at)
        status = status_of(state: "ready", tombstone: true,
                           meta: empty.to_meta.merge("state" => "ready"))
        queue = fake_queue_class.new(statuses: [status], finalized: [0], workers: [{}])

        expect(report_for(queue).run(out: out)).to eq(0)
        expect(out.string).to include("passed")
      end
    end

    context "with --min-examples above the selected count" do
      let(:config_overrides) { { min_examples: 31 } }

      it "exits 1 even though every unit passed" do
        queue = fake_queue_class.new(statuses: [ready], finalized: [3], workers: [live_workers],
                                     events: all_passed_events)
        report = report_for(queue)

        expect(report.run(out: out)).to eq(1)
        expect(out.string).to include("30 examples selected, fewer than --min-examples 31")
        expect(report.summary["verdict"]).to eq("failed")
      end
    end

    context "with --min-examples at the selected count" do
      let(:config_overrides) { { min_examples: 30 } }

      it "passes" do
        queue = fake_queue_class.new(statuses: [ready], finalized: [3], workers: [live_workers],
                                     events: all_passed_events)
        expect(report_for(queue).run(out: out)).to eq(0)
      end
    end
  end

  describe "incomplete builds" do
    let(:partial_events) do
      [
        event("delivered", unit_id: unit_ids[0], worker_id: "w1"), passed(unit_ids[0]),
        event("delivered", unit_id: unit_ids[1], worker_id: "w1"),
        event("reclaimed", unit_id: unit_ids[1], worker_id: "w2", reclaim_count: 1, previous_worker_id: "w1")
      ]
    end

    it "exits 3 when --timeout elapses, printing the gap and never-finalized units with their last worker" do
      # Workers keep heartbeating so inactivity never triggers; only the budget runs out.
      queue = fake_queue_class.new(statuses: [ready], finalized: [1], workers: [live_workers], events: partial_events)
      allow(queue).to receive(:workers) { { "w2" => { "last_seen" => clocks.wall_clock.call, "current_unit" => nil } } }
      report = report_for(queue)

      expect(report.run(out: out)).to eq(3)
      expect(clocks.slept.sum).to be >= 60
      expect(out.string).to include("incomplete: 1 of 3 units finalized after 60")
      expect(out.string).to include("never finalized: ./spec/b_spec.rb (last worker w2)")
      expect(out.string).to include("never finalized: ./spec/c_spec.rb (never delivered)")
      expect(report.summary).to include("verdict" => "incomplete", "exit_code" => 3, "finalized_count" => 1)
      expect(report.summary["never_finalized"]).to eq([
                                                        { "unit_id" => "./spec/b_spec.rb", "last_worker_id" => "w2" },
                                                        { "unit_id" => "./spec/c_spec.rb", "last_worker_id" => nil }
                                                      ])
    end

    context "when the build has been ready for a while" do
      let(:now_ms) { ready_at + 40_000 }

      it "exits 3 on inactivity measured from the most recent worker last_seen" do
        stale = { "w1" => { "last_seen" => now_ms - 25_000 }, "w2" => { "last_seen" => now_ms - 21_000 } }
        queue = fake_queue_class.new(statuses: [ready], finalized: [1], workers: [stale], events: partial_events)
        report = report_for(queue)

        expect(report.run(out: out)).to eq(3)
        expect(clocks.slept).to eq([])
        expect(out.string).to include("workers inactive for 21s")
        expect(out.string).to include("1 of 3 units finalized")
        expect(out.string).to include("never finalized: ./spec/b_spec.rb (last worker w2)")
        expect(report.summary).to include("verdict" => "incomplete", "exit_code" => 3, "workers" => stale)
      end

      it "uses ready_at instead when it is more recent than every last_seen" do
        stale = { "w1" => { "last_seen" => ready_at - 60_000 } }
        queue = fake_queue_class.new(statuses: [ready], finalized: [1], workers: [stale], events: partial_events)

        expect(report_for(queue).run(out: out)).to eq(3)
        expect(out.string).to include("workers inactive for 40s")
      end
    end

    it "measures inactivity from ready_at when no worker has checked in yet" do
      queue = fake_queue_class.new(statuses: [ready], finalized: [0], workers: [{}], events: [])
      report = report_for(queue)

      # now_ms is ready_at + 5 s; inactive_timeout is 20 s, so 16 polls of 1 s pass first.
      expect(report.run(out: out)).to eq(3)
      expect(clocks.slept.size).to eq(16)
      expect(out.string).to include("workers inactive for 21s")
    end

    it "does not trip inactivity while a worker keeps heartbeating, and completes normally" do
      queue = fake_queue_class.new(statuses: [ready], finalized: [0, 0, 0, 3], workers: [live_workers],
                                   events: all_passed_events)
      allow(queue).to receive(:workers) { { "w1" => { "last_seen" => clocks.wall_clock.call } } }

      expect(report_for(queue).run(out: out)).to eq(0)
      expect(clocks.slept.size).to eq(3)
    end

    it "treats meta vanishing mid-wait as expired" do
      queue = fake_queue_class.new(statuses: [ready], finalized: [0, RSpec::Hopper::BuildStateMissing.new("meta gone")],
                                   workers: [live_workers], events: partial_events)
      report = report_for(queue)

      expect(report.run(out: out)).to eq(3)
      expect(report.summary).to include("verdict" => "expired", "exit_code" => 3, "state" => "ready")
    end
  end

  describe "Redis errors" do
    it "exits 2 when Redis cannot be reached" do
      queue = fake_queue_class.new(statuses: [Redis::CannotConnectError.new("Connection refused")])
      report = report_for(queue)

      expect(report.run(out: out)).to eq(2)
      expect(out.string).to include("redis unreachable: Connection refused")
      expect(report.summary).to include("verdict" => "unreachable", "exit_code" => 2)
    end

    it "exits 2 when the queue reports RedisUnreachable" do
      queue = fake_queue_class.new(statuses: [ready], finalized: [RSpec::Hopper::RedisUnreachable.new("timeout")])
      expect(report_for(queue).run(out: out)).to eq(2)
    end
  end

  describe "#summary" do
    let(:errors) { [{ "class" => "RuntimeError", "message" => "boom" }] }
    let(:rich_events) do
      a, b, c = unit_ids
      [
        event("delivered", unit_id: a, worker_id: "w1"),
        event("requeued", unit_id: a, worker_id: "w1", retry_index: 1, failure_summary: "1 failure", errors: errors),
        event("delivered", unit_id: a, worker_id: "w2", retry_index: 1),
        passed(a, worker_id: "w2", retry_index: 1),
        event("delivered", unit_id: b, worker_id: "w1"),
        event("abandoned", unit_id: b, worker_id: "w1", elapsed_ms: 900_000),
        event("reclaimed", unit_id: b, worker_id: "w2", reclaim_count: 1, previous_worker_id: "w1"),
        event("reclaimed", unit_id: b, worker_id: "w3", reclaim_count: 2, previous_worker_id: "w2"),
        event("finalized", unit_id: b, worker_id: "w3", reclaim_count: 2, outcome: "failed",
                           reason: "test_failure", duration_ms: 1, errors: errors),
        event("stale_rejected", unit_id: b, worker_id: "w2", reclaim_count: 1, operation: "finalize"),
        event("delivered", unit_id: c, worker_id: "w1"),
        { "type" => "worker_error", "worker_id" => "w4", "phase" => "boot", "error_class" => "LoadError",
          "message" => "cannot load such file", "backtrace" => [], "unit_id" => nil, "at_ms" => ready_at }
      ]
    end

    it "contains every documented key with the attempt-log queries applied" do
      workers = { "w1" => { "last_seen" => now_ms - 30_000 }, "w3" => { "last_seen" => now_ms - 21_000 } }
      queue = fake_queue_class.new(statuses: [ready], finalized: [2], workers: [workers], events: rich_events)
      report = report_for(queue)
      report.run(out: out)
      summary = report.summary

      expect(summary.keys).to contain_exactly(
        "build_id", "state", "verdict", "exit_code", "message", "total_units", "total_examples", "finalized_count",
        "failed", "flaky", "never_finalized", "abandoned", "retry_counts", "reclaim_counts", "worker_errors",
        "stale_rejections", "workers", "load_errors", "file_args", "seed", "fingerprint", "revision"
      )
      expect(summary).to include(
        "build_id" => "build-42", "state" => "ready", "verdict" => "incomplete", "exit_code" => 3,
        "total_units" => 3, "total_examples" => 30, "finalized_count" => 2,
        "flaky" => ["./spec/a_spec.rb"], "abandoned" => ["./spec/b_spec.rb"],
        "retry_counts" => { "./spec/a_spec.rb" => 1 }, "reclaim_counts" => { "./spec/b_spec.rb" => 2 },
        "stale_rejections" => 1, "workers" => workers, "load_errors" => [], "file_args" => file_args,
        "seed" => 1234, "fingerprint" => "fp", "revision" => "abc"
      )
      expect(summary["failed"]).to eq([{ "unit_id" => "./spec/b_spec.rb", "reason" => "test_failure",
                                         "worker_id" => "w3", "errors" => errors }])
      expect(summary["never_finalized"]).to eq([{ "unit_id" => "./spec/c_spec.rb", "last_worker_id" => "w1" }])
      expect(summary["worker_errors"].map { |e| e["error_class"] }).to eq(["LoadError"])
      expect(out.string).to include("flaky (passed after requeue): ./spec/a_spec.rb")
      expect(out.string).to include("abandoned (exceeded --max-unit-duration): ./spec/b_spec.rb")
      expect(out.string).to include("worker error: w4 boot LoadError: cannot load such file")
      expect { JSON.generate(summary) }.not_to raise_error
    end
  end

  describe "output files" do
    let(:dir) { Dir.mktmpdir("hopper-report") }
    let(:config_overrides) do
      { summary_out: File.join(dir, "nested", "summary.json"), failed_out: File.join(dir, "failed.txt") }
    end

    after { FileUtils.remove_entry(dir) }

    it "writes the pretty JSON summary and the failed unit ids for a failed build" do
      events = [
        event("delivered", unit_id: unit_ids[0], worker_id: "w1"), passed(unit_ids[0]),
        event("delivered", unit_id: unit_ids[1], worker_id: "w1"),
        event("finalized", unit_id: unit_ids[1], worker_id: "w1", outcome: "failed", reason: "test_failure",
                           duration_ms: 1, errors: []),
        event("delivered", unit_id: unit_ids[2], worker_id: "w2")
      ]
      queue = fake_queue_class.new(statuses: [ready], finalized: [2], workers: [{ "w2" => { "last_seen" => 0 } }],
                                   events: events)
      report = report_for(queue)
      report.run(out: out)

      written = File.read(config.summary_out)
      expect(written.lines.size).to be > 5
      expect(JSON.parse(written)).to eq(report.summary)
      expect(File.read(config.failed_out)).to eq("./spec/b_spec.rb\n./spec/c_spec.rb\n")
    end

    it "writes both files for a missing build" do
      report = report_for(fake_queue_class.new(statuses: [absent]))
      report.run(out: out)

      expect(JSON.parse(File.read(config.summary_out))).to include("verdict" => "missing", "exit_code" => 2)
      expect(File.read(config.failed_out)).to eq("")
    end

    it "writes an empty failed file for a passing build" do
      queue = fake_queue_class.new(statuses: [ready], finalized: [3], workers: [live_workers],
                                   events: all_passed_events)
      report_for(queue).run(out: out)

      expect(File.read(config.failed_out)).to eq("")
      expect(JSON.parse(File.read(config.summary_out))["verdict"]).to eq("passed")
    end
  end

  it "uses real clocks by default" do
    queue = fake_queue_class.new(statuses: [ready], finalized: [3], events: all_passed_events)
    report = described_class.new(config: config, queue: queue)
    expect(report.run(out: out)).to eq(0)
  end
end
