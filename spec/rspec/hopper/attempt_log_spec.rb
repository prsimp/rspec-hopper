# frozen_string_literal: true

RSpec.describe RSpec::Hopper::AttemptLog do
  subject(:log) { described_class.new(events) }

  # Monotonic stream timestamps, 10 ms apart.
  let(:ticks) { (1..).each }
  let(:clean) { "./spec/clean_spec.rb" }
  let(:reclaimed_pass) { "./spec/reclaimed_pass_spec.rb" }
  let(:flaky_unit) { "./spec/flaky_spec.rb" }
  let(:reclaimed_then_retried) { "./spec/reclaimed_then_retried_spec.rb" }
  let(:abandoned_unit) { "./spec/abandoned_spec.rb" }
  let(:in_flight) { "./spec/in_flight_spec.rb" }
  let(:stale_unit) { "./spec/stale_spec.rb" }
  let(:budget_unit) { "./spec/budget_spec.rb" }
  let(:untouched) { "./spec/untouched_spec.rb" }
  let(:errors) { [{ "example_id" => "./spec/x_spec.rb[1:1]", "class" => "RuntimeError", "message" => "boom" }] }
  let(:events) do
    [
      # A clean unit: delivered once, passed.
      event("delivered", unit_id: clean, worker_id: "w1"),
      event("finalized", unit_id: clean, worker_id: "w1", outcome: "passed", duration_ms: 120),

      # Worker w1 died holding the unit; w2 reclaimed it and it passed on the
      # fresh attempt. No requeue, no retry budget consumed.
      event("delivered", unit_id: reclaimed_pass, worker_id: "w1"),
      event("reclaimed", unit_id: reclaimed_pass, worker_id: "w2", reclaim_count: 1, previous_worker_id: "w1"),
      event("finalized", unit_id: reclaimed_pass, worker_id: "w2", reclaim_count: 1, outcome: "passed",
                         duration_ms: 90),

      # A flaky unit: failed once with requeueable errors, requeued, passed on attempt 2.
      event("delivered", unit_id: flaky_unit, worker_id: "w1"),
      event("requeued", unit_id: flaky_unit, worker_id: "w1", retry_index: 1, failure_summary: "1 failure",
                        errors: errors),
      event("delivered", unit_id: flaky_unit, worker_id: "w3", retry_index: 1),
      event("finalized", unit_id: flaky_unit, worker_id: "w3", retry_index: 1, outcome: "passed", duration_ms: 50),

      # Reclaimed once, then requeued, then finally failed: reclaim_count
      # survives the retry and the last finalized event is failed.
      event("delivered", unit_id: reclaimed_then_retried, worker_id: "w1"),
      event("reclaimed", unit_id: reclaimed_then_retried, worker_id: "w2", reclaim_count: 1,
                         previous_worker_id: "w1"),
      event("requeued", unit_id: reclaimed_then_retried, worker_id: "w2", retry_index: 1, reclaim_count: 1,
                        failure_summary: "1 failure", errors: errors),
      event("delivered", unit_id: reclaimed_then_retried, worker_id: "w3", retry_index: 1, reclaim_count: 1),
      event("finalized", unit_id: reclaimed_then_retried, worker_id: "w3", retry_index: 1, reclaim_count: 1,
                         outcome: "failed", reason: "test_failure", duration_ms: 70, errors: errors),

      # Abandoned by w1 (exceeded max unit duration), reclaimed by w2, passed.
      event("delivered", unit_id: abandoned_unit, worker_id: "w1"),
      event("abandoned", unit_id: abandoned_unit, worker_id: "w1", elapsed_ms: 900_000),
      event("reclaimed", unit_id: abandoned_unit, worker_id: "w2", reclaim_count: 1, previous_worker_id: "w1"),
      event("finalized", unit_id: abandoned_unit, worker_id: "w2", reclaim_count: 1, outcome: "passed",
                         duration_ms: 10),

      # Still in flight: delivered to w1, reclaimed by w4, never finalized.
      event("delivered", unit_id: in_flight, worker_id: "w1"),
      event("reclaimed", unit_id: in_flight, worker_id: "w4", reclaim_count: 1, previous_worker_id: "w1"),

      # w1 was paused, w2 reclaimed and finalized, w1's late finalize was rejected.
      event("delivered", unit_id: stale_unit, worker_id: "w1"),
      event("reclaimed", unit_id: stale_unit, worker_id: "w2", reclaim_count: 1, previous_worker_id: "w1"),
      event("finalized", unit_id: stale_unit, worker_id: "w2", reclaim_count: 1, outcome: "passed", duration_ms: 5),
      event("stale_rejected", unit_id: stale_unit, worker_id: "w1", operation: "finalize"),

      # Retry budget exhausted on the requeue path.
      event("delivered", unit_id: budget_unit, worker_id: "w2"),
      event("finalized", unit_id: budget_unit, worker_id: "w2", outcome: "failed", reason: "retry_budget_exhausted",
                         duration_ms: 30, errors: errors),

      worker_error(worker_id: "w5", phase: "boot"),
      worker_error(worker_id: "w1", phase: "redis", unit_id: in_flight)
    ]
  end
  let(:manifest_units) do
    [clean, reclaimed_pass, flaky_unit, reclaimed_then_retried, abandoned_unit, in_flight, stale_unit, budget_unit,
     untouched]
  end

  def next_at_ms = 1_700_000_000_000 + (ticks.next * 10)

  # Builds one unit-scoped event with ownership_generation derived exactly as
  # the transition script derives it.
  def event(type, unit_id:, worker_id:, retry_index: 0, reclaim_count: 0, **extra)
    {
      "type" => type, "unit_id" => unit_id, "worker_id" => worker_id,
      "retry_index" => retry_index, "reclaim_count" => reclaim_count,
      "ownership_generation" => 1 + retry_index + reclaim_count, "at_ms" => next_at_ms
    }.merge(extra.transform_keys(&:to_s))
  end

  def worker_error(worker_id:, phase:, unit_id: nil)
    { "type" => "worker_error", "worker_id" => worker_id, "phase" => phase, "error_class" => "RuntimeError",
      "message" => "boom", "backtrace" => ["x.rb:1"], "unit_id" => unit_id, "at_ms" => next_at_ms }
  end

  describe "the sample log" do
    it "carries ownership_generation == 1 + retry_index + reclaim_count on every unit-scoped event" do
      scoped = log.events.select(&:unit_scoped?)
      expect(scoped).not_to be_empty
      expect(scoped).to all(be_consistent_generation)
      scoped.each do |e|
        expect(e.ownership_generation).to eq(1 + e.retry_index + e.reclaim_count)
      end
    end
  end

  describe "#failed" do
    it "returns units whose last finalized event is failed, with reason, worker and errors" do
      expect(log.failed).to eq([
                                 { unit_id: reclaimed_then_retried, reason: "test_failure", worker_id: "w3",
                                   errors: errors },
                                 { unit_id: budget_unit, reason: "retry_budget_exhausted", worker_id: "w2",
                                   errors: errors }
                               ])
    end

    it "picks the last finalized event when a unit has more than one" do
      unit = "./spec/twice_spec.rb"
      failed_then_passed = described_class.new([
                                                 event("finalized", unit_id: unit, worker_id: "w1", outcome: "failed",
                                                                    reason: "test_failure"),
                                                 event("finalized", unit_id: unit, worker_id: "w2", outcome: "passed")
                                               ])
      passed_then_failed = described_class.new([
                                                 event("finalized", unit_id: unit, worker_id: "w1", outcome: "passed"),
                                                 event("finalized", unit_id: unit, worker_id: "w2", outcome: "failed",
                                                                    reason: "test_failure")
                                               ])
      expect(failed_then_passed.failed).to eq([])
      expect(passed_then_failed.failed.map { |f| f.slice(:unit_id, :worker_id) })
        .to eq([{ unit_id: unit, worker_id: "w2" }])
    end

    it "defaults errors to an empty array" do
      unit = "./spec/no_errors_spec.rb"
      bare = described_class.new([event("finalized", unit_id: unit, worker_id: "w1", outcome: "failed",
                                                     reason: "reclaim_budget_exhausted")])
      expect(bare.failed).to eq([{ unit_id: unit, reason: "reclaim_budget_exhausted", worker_id: "w1", errors: [] }])
    end
  end

  describe "#flaky" do
    it "lists only units that were requeued and finally passed" do
      expect(log.flaky).to eq([flaky_unit])
    end

    it "does not count a unit reclaimed after worker death that passed on the fresh attempt" do
      expect(log.flaky).not_to include(reclaimed_pass)
      expect(log.flaky).not_to include(abandoned_unit)
    end

    it "does not count a requeued unit that finally failed" do
      expect(log.flaky).not_to include(reclaimed_then_retried)
    end
  end

  describe "reclaim without requeue" do
    it "keeps retry_index at 0 throughout and consumes no retry budget" do
      unit_events = log.events.select { |e| e.unit_id == reclaimed_pass }
      expect(unit_events.map(&:type)).to eq(%w[delivered reclaimed finalized])
      expect(unit_events.map(&:retry_index)).to all(eq(0))
      expect(unit_events.map(&:reclaim_count)).to eq([0, 1, 1])
      expect(log.retry_counts).not_to have_key(reclaimed_pass)
      expect(log.reclaim_counts[reclaimed_pass]).to eq(1)
    end
  end

  describe "reclaim followed by requeue" do
    it "carries the earlier reclaim_count on every event after the requeue" do
      after_requeue = log.events.select { |e| e.unit_id == reclaimed_then_retried }.drop_while do |e|
        e.type != "requeued"
      end
      expect(after_requeue.map(&:type)).to eq(%w[requeued delivered finalized])
      expect(after_requeue.map(&:reclaim_count)).to all(eq(1))
      expect(after_requeue.map(&:retry_index)).to all(eq(1))
      expect(after_requeue.map(&:ownership_generation)).to all(eq(3))
      expect(log.reclaim_counts[reclaimed_then_retried]).to eq(1)
      expect(log.retry_counts[reclaimed_then_retried]).to eq(1)
    end
  end

  describe "#never_finalized" do
    it "reports manifest units without a finalized event and the worker that last held each" do
      expect(log.never_finalized(manifest_units)).to eq([
                                                          { unit_id: in_flight, last_worker_id: "w4" },
                                                          { unit_id: untouched, last_worker_id: nil }
                                                        ])
    end

    it "uses the latest delivered event when there was no reclaim" do
      unit = "./spec/held_spec.rb"
      held = described_class.new([event("delivered", unit_id: unit, worker_id: "w9")])
      expect(held.never_finalized([unit])).to eq([{ unit_id: unit, last_worker_id: "w9" }])
    end

    it "preserves the order of the given unit ids" do
      expect(log.never_finalized([untouched, in_flight]).map { |n| n[:unit_id] }).to eq([untouched, in_flight])
    end
  end

  describe "#abandoned" do
    it "lists units with an abandoned event, once each" do
      expect(log.abandoned).to eq([abandoned_unit])
    end
  end

  describe "#retry_counts" do
    it "maps requeued units to the highest retry_index seen in requeued events" do
      expect(log.retry_counts).to eq(flaky_unit => 1, reclaimed_then_retried => 1)
    end

    it "takes the maximum across several requeues" do
      unit = "./spec/thrice_spec.rb"
      thrice = described_class.new([
                                     event("requeued", unit_id: unit, worker_id: "w1", retry_index: 1),
                                     event("requeued", unit_id: unit, worker_id: "w1", retry_index: 2),
                                     event("requeued", unit_id: unit, worker_id: "w2", retry_index: 3)
                                   ])
      expect(thrice.retry_counts).to eq(unit => 3)
    end
  end

  describe "#reclaim_counts" do
    it "counts reclaimed events per unit and omits units never reclaimed" do
      expect(log.reclaim_counts).to eq(
        reclaimed_pass => 1, reclaimed_then_retried => 1, abandoned_unit => 1, in_flight => 1, stale_unit => 1
      )
      expect(log.reclaim_counts).not_to have_key(clean)
    end
  end

  describe "#worker_errors" do
    it "returns the raw worker_error events in order" do
      expect(log.worker_errors.map { |e| e.values_at("worker_id", "phase", "unit_id") })
        .to eq([["w5", "boot", nil], ["w1", "redis", in_flight]])
      expect(log.worker_errors.first).to include("error_class" => "RuntimeError", "message" => "boom")
    end

    it "does not let a worker_error with a unit_id count as a unit lifecycle event" do
      expect(log.never_finalized([in_flight]).first[:last_worker_id]).to eq("w4")
    end
  end

  describe "#stale_rejections" do
    it "returns the raw stale_rejected events" do
      expect(log.stale_rejections).to eq([events.find { |e| e["type"] == "stale_rejected" }])
    end
  end

  describe "#finalized_events and #exactly_one_finalized?" do
    it "returns every finalized event for a unit" do
      expect(log.finalized_events(stale_unit).size).to eq(1)
      expect(log.finalized_events(in_flight)).to eq([])
    end

    it "holds for every finalized unit in the sample and fails for in-flight ones" do
      finalized = manifest_units - [in_flight, untouched]
      expect(log.exactly_one_finalized?(finalized)).to be(true)
      expect(log.exactly_one_finalized?(manifest_units)).to be(false)
    end
  end

  describe "Enumerable and #to_a" do
    it "round-trips the raw hashes and wraps each as an Event" do
      expect(log.to_a).to eq(events)
      expect(log.size).to eq(events.size)
      expect(log.first).to be_a(described_class::Event)
      expect(log.first["outcome"]).to be_nil
      expect(log.first.at_ms).to eq(events.first["at_ms"])
    end

    it "accepts symbol-keyed hashes and normalizes them" do
      sym = described_class.new([{ type: "delivered", unit_id: "./x", worker_id: "w", retry_index: 0,
                                   reclaim_count: 0, ownership_generation: 1, at_ms: 1 }])
      expect(sym.first.unit_id).to eq("./x")
      expect(sym.unit_ids).to eq(["./x"])
    end
  end

  describe "#unit_ids" do
    it "orders units by first appearance" do
      expect(log.unit_ids).to eq(manifest_units - [untouched])
    end
  end
end
