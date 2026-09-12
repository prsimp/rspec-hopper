# frozen_string_literal: true

require "spec_helper"

RSpec.describe RSpec::Hopper::Queue::RedisStreams, :redis do
  subject(:queue) { described_class.new(redis: redis, build_id: build_id, **options) }

  let(:redis) { HopperSpec::RedisHelper.new_connection }
  let(:build_id) { HopperSpec::RedisHelper.build_id }
  let(:keys) { RSpec::Hopper::Keys.new(build_id) }
  let(:unit_ids) { %w[./spec/a_spec.rb ./spec/b_spec.rb ./spec/c_spec.rb ./spec/d_spec.rb] }
  let(:options) { {} }
  let(:group) { RSpec::Hopper::Keys::CONSUMER_GROUP }

  after do
    HopperSpec::RedisHelper.delete_build(redis, build_id)
    redis.close
  end

  def build_manifest(ids = unit_ids, load_errors: [])
    RSpec::Hopper::Manifest.new(total_units: ids.size, total_examples: ids.size * 2,
                                file_counts: ids.to_h { |id| [id, 2] }, file_args: ["spec"],
                                fingerprint: "fp-#{build_id}", seed: 1234, load_errors: load_errors)
  end

  def initialize_build(ids = unit_ids, on: queue)
    token = on.acquire_leader("initializer")
    on.initialize_build(token: token, manifest: build_manifest(ids), unit_ids: ids)
  end

  def reserve_all(worker_id, on: queue)
    reservations = []
    while (reservation = on.reserve(worker_id, block_ms: 50))
      reservations << reservation
    end
    reservations
  end

  def events(type = nil)
    all = queue.attempt_events
    type ? all.select { |e| e["type"] == type.to_s } : all
  end

  def pending_row(reservation)
    redis.xpending(keys.stream(reservation.stream), group, reservation.entry_id, reservation.entry_id, 1).first
  end

  def group_info(key)
    redis.xinfo(:groups, key).find { |g| g["name"] == group }
  end

  def pttls
    HopperSpec::RedisHelper.ttls(redis, build_id)
  end

  describe "#status" do
    it "reports an uninitialized build with one MULTI" do
      allow(redis).to receive(:multi).and_call_original
      status = queue.status
      expect(status).to have_attributes(state: nil, tombstone: false, meta: nil)
      expect(redis).to have_received(:multi).once
    end

    it "reports a ready build with its meta" do
      initialize_build
      status = queue.status
      expect(status).to have_attributes(state: "ready", tombstone: true)
      expect(status.meta).to include("state" => "ready", "total_units" => "4")
    end
  end

  describe "#initialize_build" do
    let(:options) { { tombstone_ttl: 100 } }

    before { initialize_build }

    it "creates both consumer groups at id 0 before any read" do
      [keys.units, keys.units_priority].each do |key|
        expect(group_info(key)).to include("last-delivered-id" => "0-0", "pending" => 0, "consumers" => 0)
      end
      expect(redis.xlen(keys.units)).to eq(unit_ids.size)
      expect(redis.xlen(keys.units_priority)).to eq(0)
    end

    it "delivers every seeded unit exactly once across repeated reserves" do
      delivered = reserve_all("w1") + reserve_all("w2")
      expect(delivered.map(&:unit_id).sort).to eq(unit_ids.sort)
      expect(delivered.map(&:unit_id).uniq.size).to eq(unit_ids.size)
      expect(queue.reserve("w1", block_ms: 50)).to be_nil
    end

    it "writes unit_state for every unit immediately after ready" do
      expect(queue.unit_states).to eq(unit_ids.to_h do |id|
        [id, { "retry_index" => 0, "reclaim_count" => 0, "entered_retry" => false }]
      end)
    end

    it "publishes meta with the runtime fields and the frozen budgets" do
      meta = queue.status.meta
      expect(meta).to include("state" => "ready", "finalized_count" => "0", "requeued_units_count" => "0",
                              "total_units" => "4", "fingerprint" => "fp-#{build_id}", "seed" => "1234",
                              "max_requeues" => "0", "requeue_tolerance" => "0.0", "max_reclaims" => "3",
                              "timeout" => "180", "ttl" => "14400")
      expect(Integer(meta["ready_at"])).to be > 1_600_000_000_000
      expect(queue.manifest).to have_attributes(total_units: 4, fingerprint: "fp-#{build_id}", seed: 1234)
      expect(queue.total_units).to eq(4)
      expect(queue.finalized_count).to eq(0)
    end

    it "writes the tombstone with the tombstone TTL and gives every key a positive TTL" do
      ttls = pttls
      expect(ttls.keys).to contain_exactly(keys.units, keys.units_priority, keys.meta, keys.unit_state, keys.leader,
                                           keys.exists)
      expect(ttls.values).to all(be_positive)
      expect(ttls[keys.exists]).to be_between(90_000, 100_000)
      expect(ttls[keys.leader]).to be_between(50_000, 60_000)
      expect(ttls[keys.meta]).to be_between(14_000_000, 14_400_000)
    end

    it "enforces the initializer's budgets over a joining worker's flags" do
      other = described_class.new(redis: redis, build_id: build_id, max_requeues: 5)
      reservation = other.reserve("w1")
      result = other.requeue(reservation, duration_ms: 1, failure_summary: "1 failure", errors: [])
      expect(result).to have_attributes(status: :finalized, retry_index: 0)
      expect(events(:finalized).first).to include("reason" => "retry_budget_exhausted")
    end
  end

  describe "initialization fencing" do
    it "raises LeaseLost for a wrong lease token and writes nothing" do
      queue.acquire_leader("w1")
      expect { queue.initialize_build(token: "w2:bogus", manifest: build_manifest, unit_ids: unit_ids) }
        .to raise_error(RSpec::Hopper::LeaseLost)
      expect(queue.keys).to eq([keys.leader])
    end

    it "returns nil from acquire_leader while another worker holds the lease" do
      expect(queue.acquire_leader("w1")).to start_with("w1:")
      expect(queue.acquire_leader("w2")).to be_nil
    end

    it "raises PreviouslyInitialized when the tombstone exists and leaves the streams untouched" do
      initialize_build
      first = queue.reserve("w1")
      redis.del(keys.meta, keys.leader)
      token = queue.acquire_leader("w2")

      expect { queue.initialize_build(token: token, manifest: build_manifest, unit_ids: unit_ids) }
        .to raise_error(RSpec::Hopper::PreviouslyInitialized)
      expect(redis.exists(keys.meta)).to eq(0)
      expect(redis.xlen(keys.units)).to eq(unit_ids.size)
      expect(group_info(keys.units)).to include("last-delivered-id" => first.entry_id, "pending" => 1)
    end

    it "raises AlreadyInitialized when meta is present without a tombstone" do
      initialize_build
      redis.del(keys.exists, keys.leader)
      token = queue.acquire_leader("w2")
      expect { queue.initialize_build(token: token, manifest: build_manifest, unit_ids: unit_ids) }
        .to raise_error(RSpec::Hopper::AlreadyInitialized)
    end

    it "records init_failed with the load errors and the tombstone, and no unit keys" do
      token = queue.acquire_leader("w1")
      manifest = build_manifest([], load_errors: ["spec/broken_spec.rb: NameError"])
      expect(queue.fail_initialization(token: token, manifest: manifest)).to eq(:init_failed)

      status = queue.status
      expect(status).to have_attributes(state: "init_failed", tombstone: true)
      expect(JSON.parse(status.meta["load_errors"])).to eq(["spec/broken_spec.rb: NameError"])
      expect(queue.keys).to eq([keys.exists, keys.leader, keys.meta])
      expect(pttls.values).to all(be_positive)
      expect { queue.initialize_build(token: token, manifest: build_manifest, unit_ids: unit_ids) }
        .to raise_error(RSpec::Hopper::PreviouslyInitialized)
    end
  end

  describe "#reserve" do
    let(:options) { { max_requeues: 1, requeue_tolerance: 1.0 } }

    before { initialize_build }

    it "records delivery accounting with the handle and counters" do
      reservation = queue.reserve("w1")
      expect(reservation).to have_attributes(unit_id: unit_ids.first, unit_type: "file", stream: "units",
                                             consumer: "w1", delivery_count: 1, retry_index: 0, reclaim_count: 0)
      expect(reservation.ownership_generation).to eq(1)
      expect(pending_row(reservation)).to include("consumer" => "w1", "count" => 1)

      event = events(:delivered).first
      expect(event).to include("unit_id" => unit_ids.first, "worker_id" => "w1", "retry_index" => 0,
                               "reclaim_count" => 0, "ownership_generation" => 1, "stream" => "units",
                               "entry_id" => reservation.entry_id, "delivery_count" => 1)
      expect(event["at_ms"]).to be_a(Integer)
      expect(queue.workers["w1"]).to include("current_unit" => unit_ids.first, "processed" => 0)
    end

    it "prefers units:priority over untouched units" do
      first = queue.reserve("w1")
      queue.requeue(first, duration_ms: 1, failure_summary: "1 failure", errors: [])

      retried = queue.reserve("w2")
      expect(retried).to have_attributes(unit_id: first.unit_id, stream: "units:priority", retry_index: 1,
                                         reclaim_count: 0, delivery_count: 1)
      # A reservation is the pair (stream, entry_id): ids are unique only within
      # a stream, so the new priority entry can carry the id the units entry had
      # when both XADDs land in the same millisecond.
      expect([retried.stream, retried.entry_id]).not_to eq([first.stream, first.entry_id])
      expect(pending_row(first)).to be_nil
      expect(queue.reserve("w2").unit_id).to eq(unit_ids[1])
    end

    it "returns nil after blocking on an empty queue" do
      reserve_all("w1")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(queue.reserve("w1", block_ms: 150)).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.14
    end

    it "returns nil when the entry was reclaimed between the read and delivery accounting" do
      key = keys.units
      entry_id = redis.xreadgroup(group, "w1", key, ">", count: 1)[key].first[0]
      redis.xclaim(key, group, "w2", 0, entry_id)
      reply = queue.send(:transition, "delivery_accounting", "w1", "units", entry_id, unit_ids.first)
      expect(reply).to eq(["STALE"])
      expect(events).to be_empty
    end

    it "raises CorruptBuild when the stream and its group are gone" do
      redis.del(keys.units, keys.units_priority)
      expect { queue.reserve("w1", block_ms: 50) }.to raise_error(RSpec::Hopper::CorruptBuild, /NOGROUP/)
    end
  end

  describe "#heartbeat" do
    before { initialize_build }

    let(:reservation) { queue.reserve("w1") }

    it "succeeds for the owner and resets the entry's idle time without touching delivery count" do
      reservation
      sleep 0.15
      expect(pending_row(reservation)["elapsed"]).to be >= 100

      expect(queue.heartbeat(reservation)).to be(true)
      expect(pending_row(reservation)).to include("consumer" => "w1", "count" => 1)
      expect(pending_row(reservation)["elapsed"]).to be < 100
      expect(queue.workers["w1"]).to include("current_unit" => reservation.unit_id)
    end

    it "raises StaleReservation for a handle with a different delivery count" do
      stale = reservation.with(delivery_count: 2)
      expect { queue.heartbeat(stale) }.to raise_error(RSpec::Hopper::StaleReservation)
    end

    it "raises StaleReservation for a handle with a different consumer" do
      stale = reservation.with(consumer: "w2")
      expect { queue.heartbeat(stale) }.to raise_error(RSpec::Hopper::StaleReservation)
      expect(pending_row(reservation)).to include("consumer" => "w1")
    end

    it "still works after the server forgets the scripts" do
      reservation
      redis.script(:flush)
      expect(queue.heartbeat(reservation)).to be(true)
    end
  end

  describe "#reclaim_lost" do
    let(:options) { { timeout: 0.2, max_reclaims: 1, max_requeues: 2, requeue_tolerance: 1.0 } }

    before { initialize_build }

    it "returns nil when nothing is idle past the timeout" do
      queue.reserve("w1")
      expect(queue.reclaim_lost("w2")).to be_nil
      expect(events(:reclaimed)).to be_empty
    end

    it "claims an idle entry atomically with reclaim accounting and fences the old owner" do
      lost = queue.reserve("w1")
      sleep 0.3

      reclaimed = queue.reclaim_lost("w2")
      expect(reclaimed).to have_attributes(unit_id: lost.unit_id, unit_type: "file", stream: "units",
                                           entry_id: lost.entry_id, consumer: "w2", delivery_count: 2,
                                           retry_index: 0, reclaim_count: 1)
      expect(pending_row(reclaimed)).to include("consumer" => "w2", "count" => reclaimed.delivery_count)
      expect(queue.unit_states[lost.unit_id]).to include("reclaim_count" => 1, "retry_index" => 0)

      event = events(:reclaimed).first
      expect(event).to include("unit_id" => lost.unit_id, "worker_id" => "w2", "previous_worker_id" => "w1",
                               "reclaim_count" => 1, "retry_index" => 0, "ownership_generation" => 2,
                               "delivery_count" => 2, "stream" => "units", "entry_id" => lost.entry_id)

      expect { queue.heartbeat(lost) }.to raise_error(RSpec::Hopper::StaleReservation)
      expect { queue.finalize(lost, outcome: :passed, duration_ms: 1) }
        .to raise_error(RSpec::Hopper::StaleReservation)
      expect { queue.requeue(lost, duration_ms: 1, failure_summary: "x", errors: []) }
        .to raise_error(RSpec::Hopper::StaleReservation)

      expect(queue.finalize(reclaimed, outcome: :passed, duration_ms: 1)).to be(true)
      expect(events(:finalized).size).to eq(1)
      expect(events(:finalized).first).to include("worker_id" => "w2", "outcome" => "passed", "reclaim_count" => 1)
      expect(queue.finalized_count).to eq(1)
    end

    it "reclaims entries from units:priority" do
      first = queue.reserve("w1")
      queue.requeue(first, duration_ms: 1, failure_summary: "1 failure", errors: [])
      retried = queue.reserve("w1")
      expect(retried.stream).to eq("units:priority")
      sleep 0.3

      reclaimed = queue.reclaim_lost("w2")
      expect(reclaimed).to have_attributes(unit_id: first.unit_id, stream: "units:priority",
                                           entry_id: retried.entry_id, retry_index: 1, reclaim_count: 1)
      expect(reclaimed.ownership_generation).to eq(3)
      expect(events(:reclaimed).first).to include("stream" => "units:priority", "previous_worker_id" => "w1")
    end

    it "keeps reclaim_count across a later retry" do
      lost = queue.reserve("w1")
      sleep 0.3
      reclaimed = queue.reclaim_lost("w2")
      queue.requeue(reclaimed, duration_ms: 1, failure_summary: "1 failure", errors: [])

      retried = queue.reserve("w3")
      expect(retried).to have_attributes(unit_id: lost.unit_id, retry_index: 1, reclaim_count: 1)
      expect(retried.ownership_generation).to eq(3)
    end

    it "finalizes the unit as failed once the reclaim budget is exhausted" do
      lost = queue.reserve("w1")
      sleep 0.3
      queue.reclaim_lost("w2")
      sleep 0.3

      expect(queue.reclaim_lost("w3")).to be_nil
      finalized = events(:finalized)
      expect(finalized.size).to eq(1)
      expect(finalized.first).to include("unit_id" => lost.unit_id, "worker_id" => "w3", "outcome" => "failed",
                                         "reason" => "reclaim_budget_exhausted", "previous_worker_id" => "w2",
                                         "reclaim_count" => 1, "ownership_generation" => 2)
      expect(queue.finalized_count).to eq(1)
      expect(queue.unit_states[lost.unit_id]).to include("reclaim_count" => 1)
      expect(redis.xpending(keys.units, group)["size"]).to eq(0)
      expect(events(:reclaimed).size).to eq(1)
    end

    it "raises CorruptBuild without moving ownership when the unit's state is gone" do
      lost = queue.reserve("w1")
      sleep 0.3
      redis.hdel(keys.unit_state, lost.unit_id)

      expect { queue.reclaim_lost("w2") }.to raise_error(RSpec::Hopper::CorruptBuild)
      expect(pending_row(lost)).to include("consumer" => "w1", "count" => 1)
    end
  end

  describe "#finalize" do
    before { initialize_build }

    it "acks the entry, appends finalized and increments finalized_count" do
      reservation = queue.reserve("w1")
      errors = [{ "example_id" => "./spec/a_spec.rb[1:1]", "class" => "RuntimeError", "message" => "boom",
                  "backtrace" => [] }]
      expect(queue.finalize(reservation, outcome: :failed, duration_ms: 42, reason: "test_failure",
                                         errors: errors)).to be(true)

      expect(pending_row(reservation)).to be_nil
      expect(queue.finalized_count).to eq(1)
      expect(queue.workers["w1"]).to include("current_unit" => nil, "processed" => 1)
      event = events(:finalized).first
      expect(event).to include("unit_id" => reservation.unit_id, "worker_id" => "w1", "outcome" => "failed",
                               "duration_ms" => 42, "reason" => "test_failure", "errors" => errors,
                               "stream" => "units", "entry_id" => reservation.entry_id,
                               "retry_index" => 0, "reclaim_count" => 0, "ownership_generation" => 1)
    end

    it "records a pass with null reason and errors" do
      reservation = queue.reserve("w1")
      queue.finalize(reservation, outcome: "passed", duration_ms: 7)
      expect(events(:finalized).first).to include("outcome" => "passed", "reason" => nil, "errors" => nil)
    end

    it "rejects a failed outcome without a reason" do
      reservation = queue.reserve("w1")
      expect { queue.finalize(reservation, outcome: :failed, duration_ms: 1) }.to raise_error(ArgumentError)
    end

    it "raises StaleReservation a second time for the same handle" do
      reservation = queue.reserve("w1")
      queue.finalize(reservation, outcome: :passed, duration_ms: 1)
      expect { queue.finalize(reservation, outcome: :passed, duration_ms: 1) }
        .to raise_error(RSpec::Hopper::StaleReservation)
      expect(events(:finalized).size).to eq(1)
    end
  end

  describe "#requeue" do
    let(:options) { { max_requeues: 2, requeue_tolerance: 1.0 } }

    before { initialize_build }

    it "moves the unit to units:priority with retry accounting" do
      first = queue.reserve("w1")
      errors = [{ "class" => "RuntimeError", "message" => "flaky", "backtrace" => ["a.rb:1"] }]
      result = queue.requeue(first, duration_ms: 9, failure_summary: "1 failure", errors: errors)
      expect(result).to have_attributes(status: :requeued, retry_index: 1)
      expect(result).to be_requeued

      expect(queue.unit_states[first.unit_id]).to eq("retry_index" => 1, "reclaim_count" => 0,
                                                     "entered_retry" => true)
      expect(queue.status.meta["requeued_units_count"]).to eq("1")
      expect(pending_row(first)).to be_nil
      expect(redis.xlen(keys.units_priority)).to eq(1)
      expect(queue.workers["w1"]).to include("current_unit" => nil, "processed" => 1)

      event = events(:requeued).first
      expect(event).to include("unit_id" => first.unit_id, "worker_id" => "w1", "retry_index" => 1,
                               "previous_retry_index" => 0, "reclaim_count" => 0, "ownership_generation" => 2,
                               "duration_ms" => 9, "failure_summary" => "1 failure", "errors" => errors,
                               "stream" => "units", "entry_id" => first.entry_id)
      expect(event["new_entry_id"]).to be_a(String)

      retried = queue.reserve("w2")
      expect(retried).to have_attributes(unit_id: first.unit_id, stream: "units:priority",
                                         entry_id: event["new_entry_id"], retry_index: 1, reclaim_count: 0)
    end

    it "counts a unit in requeued_units_count only once" do
      first = queue.reserve("w1")
      queue.requeue(first, duration_ms: 1, failure_summary: "1 failure", errors: [])
      second = queue.reserve("w1")
      expect(queue.requeue(second, duration_ms: 1, failure_summary: "1 failure", errors: []))
        .to have_attributes(status: :requeued, retry_index: 2)
      expect(queue.status.meta["requeued_units_count"]).to eq("1")
    end

    it "finalizes as failed with retry_budget_exhausted once max_requeues is exceeded" do
      first = queue.reserve("w1")
      queue.requeue(first, duration_ms: 1, failure_summary: "1 failure", errors: [])
      second = queue.reserve("w1")
      queue.requeue(second, duration_ms: 1, failure_summary: "1 failure", errors: [])
      third = queue.reserve("w1")
      expect(third.retry_index).to eq(2)

      result = queue.requeue(third, duration_ms: 3, failure_summary: "1 failure", errors: [{ "class" => "E" }])
      expect(result).to have_attributes(status: :finalized, retry_index: 2)
      expect(result).to be_finalized
      expect(pending_row(third)).to be_nil
      expect(queue.finalized_count).to eq(1)
      expect(events(:finalized).first).to include("outcome" => "failed", "reason" => "retry_budget_exhausted",
                                                  "failure_summary" => "1 failure", "errors" => [{ "class" => "E" }],
                                                  "retry_index" => 2, "ownership_generation" => 3, "duration_ms" => 3)
      expect(queue.unit_states[first.unit_id]).to include("retry_index" => 2)
    end

    context "with max_requeues at zero" do
      let(:options) { { max_requeues: 0, requeue_tolerance: 1.0 } }

      it "finalizes the first failure" do
        reservation = queue.reserve("w1")
        result = queue.requeue(reservation, duration_ms: 1, failure_summary: "1 failure", errors: [])
        expect(result).to have_attributes(status: :finalized, retry_index: 0)
        expect(queue.status.meta["requeued_units_count"]).to eq("0")
        expect(queue.unit_states[reservation.unit_id]).to include("entered_retry" => false)
      end
    end

    context "with a tolerance allowing one distinct unit" do
      let(:options) { { max_requeues: 5, requeue_tolerance: 0.25 } }

      it "finalizes the second distinct unit while the first keeps retrying" do
        first = queue.reserve("w1")
        second = queue.reserve("w2")
        expect(queue.requeue(first, duration_ms: 1, failure_summary: "1 failure", errors: [])).to be_requeued
        expect(queue.requeue(second, duration_ms: 1, failure_summary: "1 failure", errors: [])).to be_finalized
        expect(events(:finalized).first).to include("unit_id" => second.unit_id, "reason" => "retry_budget_exhausted")

        first_again = queue.reserve("w1")
        expect(first_again.unit_id).to eq(first.unit_id)
        expect(queue.requeue(first_again, duration_ms: 1, failure_summary: "1 failure", errors: []))
          .to have_attributes(status: :requeued, retry_index: 2)
        expect(queue.status.meta["requeued_units_count"]).to eq("1")
      end
    end
  end

  describe "ownership_generation" do
    let(:options) { { timeout: 0.2, max_requeues: 3, requeue_tolerance: 1.0 } }

    it "equals 1 + retry_index + reclaim_count in every unit-scoped event" do
      initialize_build
      first = queue.reserve("w1")
      queue.requeue(first, duration_ms: 1, failure_summary: "f", errors: [])
      retried = queue.reserve("w1")
      queue.record_abandoned(retried, elapsed_ms: 5)
      sleep 0.3
      reclaimed = queue.reclaim_lost("w2")
      queue.record_stale_rejected(retried, operation: :finalize)
      queue.finalize(reclaimed, outcome: :passed, duration_ms: 1)

      unit_events = events.reject { |e| e["type"] == "worker_error" }
      expect(unit_events.map { |e| e["type"] })
        .to eq(%w[delivered requeued delivered abandoned reclaimed stale_rejected finalized])
      unit_events.each do |event|
        expect(event["ownership_generation"]).to eq(1 + event["retry_index"] + event["reclaim_count"])
      end
      expect(unit_events.last).to include("retry_index" => 1, "reclaim_count" => 1, "ownership_generation" => 3)
    end
  end

  describe "corruption" do
    before { initialize_build }

    it "raises CorruptBuild from finalize and requeue when the unit's state entry is gone" do
      reservation = queue.reserve("w1")
      redis.hdel(keys.unit_state, reservation.unit_id)
      expect { queue.finalize(reservation, outcome: :passed, duration_ms: 1) }
        .to raise_error(RSpec::Hopper::CorruptBuild)
      expect { queue.requeue(reservation, duration_ms: 1, failure_summary: "f", errors: []) }
        .to raise_error(RSpec::Hopper::CorruptBuild)
      expect(redis.hlen(keys.unit_state)).to eq(unit_ids.size - 1)
      expect(events(:finalized)).to be_empty
    end

    it "raises BuildStateMissing and CorruptBuild once meta is gone" do
      reservation = queue.reserve("w1")
      redis.del(keys.meta)
      expect { queue.complete? }.to raise_error(RSpec::Hopper::BuildStateMissing)
      expect { queue.finalized_count }.to raise_error(RSpec::Hopper::BuildStateMissing)
      expect { queue.total_units }.to raise_error(RSpec::Hopper::BuildStateMissing)
      expect { queue.touch_liveness("w1") }.to raise_error(RSpec::Hopper::CorruptBuild)
      expect { queue.heartbeat(reservation) }.to raise_error(RSpec::Hopper::CorruptBuild)
      expect { queue.reclaim_lost("w2") }.to raise_error(RSpec::Hopper::CorruptBuild)
      expect(queue.status).to have_attributes(state: nil, tombstone: true, meta: nil)
      expect(queue.manifest).to be_nil
    end
  end

  describe "#record_worker_error" do
    it "works before any initialization and gives the attempts key a TTL" do
      error = RuntimeError.new("boot exploded")
      error.set_backtrace(%w[a.rb:1 b.rb:2])
      expect(queue.record_worker_error(worker_id: "w1", phase: :boot, error: error)).to be(true)

      expect(queue.keys).to eq([keys.attempts])
      expect(pttls[keys.attempts]).to be_positive
      event = events(:worker_error).first
      expect(event).to include("type" => "worker_error", "worker_id" => "w1", "phase" => "boot", "unit_id" => nil,
                               "class" => "RuntimeError", "message" => "boot exploded",
                               "backtrace" => %w[a.rb:1 b.rb:2])
      expect(event["at_ms"]).to be_a(Integer)
    end

    it "caps the message and backtrace and carries the unit id" do
      error = RuntimeError.new("x" * 10_000)
      error.set_backtrace(Array.new(50) { |i| "line#{i}" })
      queue.record_worker_error(worker_id: "w1", phase: "execution", error: error, unit_id: unit_ids.first)
      event = events(:worker_error).first
      expect(event["message"].bytesize).to be <= RSpec::Hopper::ErrorPayload::MESSAGE_BYTES
      expect(event["backtrace"].size).to eq(RSpec::Hopper::ErrorPayload::BACKTRACE_LINES)
      expect(event["unit_id"]).to eq(unit_ids.first)
    end

    it "rejects an unknown phase" do
      expect { queue.record_worker_error(worker_id: "w1", phase: :nope, error: RuntimeError.new) }
        .to raise_error(ArgumentError)
    end
  end

  describe "#record_stale_rejected" do
    it "records the operation and the handle's unit and counters without fencing" do
      initialize_build
      reservation = queue.reserve("w1")
      stale = reservation.with(delivery_count: 7, retry_index: 1, reclaim_count: 2)
      expect(queue.record_stale_rejected(stale, operation: :finalize)).to be(true)

      event = events(:stale_rejected).first
      expect(event).to include("type" => "stale_rejected", "unit_id" => reservation.unit_id, "worker_id" => "w1",
                               "operation" => "finalize", "retry_index" => 1, "reclaim_count" => 2,
                               "ownership_generation" => 4, "stream" => "units",
                               "entry_id" => reservation.entry_id, "delivery_count" => 7)
      expect(event["at_ms"]).to be_a(Integer)
    end
  end

  describe "#record_abandoned" do
    before { initialize_build }

    it "appends abandoned with elapsed_ms for the owner" do
      reservation = queue.reserve("w1")
      expect(queue.record_abandoned(reservation, elapsed_ms: 900_123)).to be(true)
      expect(events(:abandoned).first).to include("unit_id" => reservation.unit_id, "worker_id" => "w1",
                                                  "elapsed_ms" => 900_123, "ownership_generation" => 1)
      expect(pending_row(reservation)).to include("consumer" => "w1")
    end

    it "is fenced" do
      reservation = queue.reserve("w1")
      expect { queue.record_abandoned(reservation.with(consumer: "w2"), elapsed_ms: 1) }
        .to raise_error(RSpec::Hopper::StaleReservation)
      expect(events(:abandoned)).to be_empty
    end
  end

  describe "#touch_liveness" do
    before { initialize_build }

    it "writes last_seen and current_unit for the worker" do
      before_ms = (Process.clock_gettime(Process::CLOCK_REALTIME) * 1000).to_i
      expect(queue.touch_liveness("idle")).to be(true)
      expect(queue.workers["idle"]).to include("current_unit" => nil, "processed" => 0)
      expect(queue.workers["idle"]["last_seen"]).to be >= before_ms - 1000

      queue.touch_liveness("idle", current_unit: unit_ids.first)
      expect(queue.workers["idle"]).to include("current_unit" => unit_ids.first)
      expect(pttls[keys.workers]).to be_positive
    end
  end

  describe "TTL renewal" do
    let(:options) { { ttl: 2 } }

    before { initialize_build }

    def live_keys
      [keys.units, keys.units_priority, keys.attempts, keys.meta, keys.unit_state, keys.workers]
    end

    it "renews every live key on heartbeat, finalize and liveness but never leader or exists" do
      reservation = queue.reserve("w1")
      sleep 0.5
      aged = pttls
      expect(aged[keys.meta]).to be < 1_600
      leader_before = aged[keys.leader]
      exists_before = aged[keys.exists]

      queue.heartbeat(reservation)
      renewed = pttls
      live_keys.each { |k| expect(renewed[k]).to be_between(1_800, 2_000) }
      expect(renewed[keys.leader]).to be <= leader_before
      expect(renewed[keys.exists]).to be <= exists_before

      sleep 0.3
      queue.finalize(reservation, outcome: :passed, duration_ms: 1)
      live_keys.each { |k| expect(pttls[k]).to be_between(1_800, 2_000) }

      sleep 0.3
      queue.touch_liveness("w2")
      live_keys.each { |k| expect(pttls[k]).to be_between(1_800, 2_000) }
    end

    it "leaves every key with a positive TTL after a full run" do
      reserve_all("w1").each { |r| queue.finalize(r, outcome: :passed, duration_ms: 1) }
      queue.record_worker_error(worker_id: "w2", phase: :reserve, error: RuntimeError.new("x"))
      expect(pttls.values).to all(be_positive)
      expect(pttls.keys).to match_array(live_keys + [keys.leader, keys.exists])
    end
  end

  describe "completion" do
    before { initialize_build }

    it "is complete only when finalized_count equals total_units" do
      reservations = reserve_all("w1")
      reservations[0..-2].each { |r| queue.finalize(r, outcome: :passed, duration_ms: 1) }
      expect(queue.complete?).to be(false)
      expect(queue.finalized_count).to eq(unit_ids.size - 1)

      queue.finalize(reservations.last, outcome: :failed, duration_ms: 1, reason: "test_failure", errors: [])
      expect(queue.complete?).to be(true)
      expect(queue.finalized_count).to eq(queue.total_units)
      expect(events(:finalized).map { |e| e["unit_id"] }.sort).to eq(unit_ids.sort)
    end

    it "treats a zero-unit build as complete" do
      other_id = HopperSpec::RedisHelper.build_id
      other = described_class.new(redis: redis, build_id: other_id)
      initialize_build([], on: other)
      expect(other.complete?).to be(true)
      expect(other.reserve("w1", block_ms: 50)).to be_nil
      expect(other.keys).not_to include(RSpec::Hopper::Keys.new(other_id).unit_state)
    ensure
      HopperSpec::RedisHelper.delete_build(redis, other_id) if other_id
    end
  end
end
