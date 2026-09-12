# frozen_string_literal: true

require "securerandom"

module HopperSpec
  # Deterministic time for worker and heartbeat specs.
  class FakeClock
    attr_reader :now

    def initialize(start = 1_000.0)
      @now = start.to_f
    end

    def advance(seconds) = @now += seconds
    def call = now
    def to_proc = -> { now }
  end

  # In-memory implementation of the Queue interface table in docs/DESIGN.md,
  # including fencing, retry/reclaim accounting and the retry-budget rules.
  # Mutations return true like the real adapter.
  # rubocop:disable-next Naming/PredicateMethod
  class FakeQueue
    include RSpec::Hopper

    Entry = Struct.new(:entry_id, :unit_id, :unit_type, :stream, :consumer, :delivery_count, :acked,
                       keyword_init: true)

    attr_reader :build_id, :events, :meta, :unit_states, :workers, :streams, :leader, :tombstone, :heartbeats,
                :max_requeues, :requeue_tolerance, :max_reclaims

    def initialize(build_id: "fake-build", max_requeues: 0, requeue_tolerance: 0.0, max_reclaims: 3, clock: nil)
      @build_id = build_id
      @max_requeues = max_requeues
      @requeue_tolerance = requeue_tolerance
      @max_reclaims = max_reclaims
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_REALTIME) }
      @streams = { "units" => [], "units:priority" => [] }
      @events = []
      @unit_states = {}
      @workers = {}
      @heartbeats = []
      @reclaimable = []
      @meta = nil
      @leader = nil
      @tombstone = false
      @next_id = 0
    end

    # --- status and initialization ---------------------------------------------

    def status = Queue::Status.new(state: @meta&.fetch("state"), tombstone: @tombstone, meta: @meta&.dup)

    def acquire_leader(worker_id)
      return nil if @leader

      @leader = "#{worker_id}:#{SecureRandom.hex(4)}"
    end

    def initialize_build(token:, manifest:, unit_ids:)
      check_initialization!(token)
      @streams.each_value(&:clear)
      unit_ids.each do |id|
        @streams["units"] << new_entry(id, "units")
        @unit_states[id] = { "retry_index" => 0, "reclaim_count" => 0, "entered_retry" => false }
      end
      @meta = manifest.with(ready_at: now_ms).to_meta
                      .merge("state" => "ready", "finalized_count" => "0", "requeued_units_count" => "0")
      @tombstone = true
      :ready
    end

    def fail_initialization(token:, manifest:)
      check_initialization!(token)
      @meta = manifest.with(ready_at: now_ms).to_meta.merge("state" => "init_failed")
      @tombstone = true
      :init_failed
    end

    def manifest = @meta && Manifest.from_meta(@meta)

    # --- reservation -----------------------------------------------------------

    def reclaim_lost(worker_id)
      unit_id = @reclaimable.shift
      unit_id && reclaim!(unit_id, by: worker_id)
    end

    def reserve(worker_id, block_ms: 1000) # rubocop:disable Lint/UnusedMethodArgument
      entry = %w[units:priority units].filter_map { |s| @streams[s].find { |e| e.consumer.nil? && !e.acked } }.first
      return nil unless entry

      entry.consumer = worker_id
      entry.delivery_count = 1
      append("delivered", entry, worker_id)
      touch(worker_id, current_unit: entry.unit_id)
      reservation(entry)
    end

    def heartbeat(reservation)
      entry = fence!(reservation)
      @heartbeats << reservation
      touch(reservation.consumer, current_unit: entry.unit_id)
      true
    end

    def finalize(reservation, outcome:, duration_ms:, reason: nil, errors: nil)
      entry = fence!(reservation)
      unit_state!(entry.unit_id)
      finalize_entry(entry, reservation.consumer, outcome: outcome, duration_ms: duration_ms, reason: reason,
                                                  errors: errors)
      true
    end

    def requeue(reservation, duration_ms:, failure_summary:, errors:)
      entry = fence!(reservation)
      state = unit_state!(entry.unit_id)
      if retry_budget_exhausted?(state)
        finalize_entry(entry, reservation.consumer, outcome: :failed, duration_ms: duration_ms,
                                                    reason: "retry_budget_exhausted", errors: errors)
        return Queue::RequeueResult.new(status: :finalized, retry_index: state["retry_index"])
      end
      unless state["entered_retry"]
        state["entered_retry"] = true
        @meta["requeued_units_count"] = (@meta["requeued_units_count"].to_i + 1).to_s
      end
      state["retry_index"] += 1
      entry.acked = true
      @streams["units:priority"].unshift(new_entry(entry.unit_id, "units:priority"))
      append("requeued", entry, reservation.consumer, "failure_summary" => failure_summary, "errors" => errors,
                                                      "duration_ms" => duration_ms)
      touch(reservation.consumer, current_unit: nil, processed: 1)
      Queue::RequeueResult.new(status: :requeued, retry_index: state["retry_index"])
    end

    # --- events -----------------------------------------------------------------

    def record_worker_error(worker_id:, phase:, error:, unit_id: nil)
      @events << { "type" => "worker_error", "worker_id" => worker_id, "phase" => phase, "unit_id" => unit_id,
                   "class" => error.class.name, "message" => error.message.to_s,
                   "backtrace" => Array(error.backtrace).first(20), "at_ms" => now_ms }
      true
    end

    def record_stale_rejected(reservation, operation:)
      @events << unit_fields(reservation).merge("type" => "stale_rejected", "operation" => operation.to_s,
                                                "at_ms" => now_ms)
      true
    end

    def record_abandoned(reservation, elapsed_ms:)
      entry = fence!(reservation)
      append("abandoned", entry, reservation.consumer, "elapsed_ms" => elapsed_ms)
      true
    end

    def touch_liveness(worker_id, current_unit: nil)
      raise CorruptBuild, "meta missing" unless @meta

      touch(worker_id, current_unit: current_unit)
      true
    end

    # --- reads ------------------------------------------------------------------

    def complete? = finalized_count == total_units
    def finalized_count = meta!["finalized_count"].to_i
    def total_units = meta!["total_units"].to_i
    def attempt_events = @events.dup
    def events_of(type) = @events.select { |e| e["type"] == type }
    def keys = Keys.new(build_id).all

    # --- test hooks -------------------------------------------------------------

    def seed_ready!(manifest, unit_ids = manifest.unit_ids)
      expire_leader!
      initialize_build(token: acquire_leader("seeder"), manifest: manifest, unit_ids: unit_ids)
      @leader = nil
    end

    def seed_init_failed!(manifest)
      expire_leader!
      fail_initialization(token: acquire_leader("seeder"), manifest: manifest)
      @leader = nil
    end

    def tombstone_only! = (@tombstone = true) && (@meta = nil)
    def vanish_meta! = @meta = nil
    def expire_leader! = @leader = nil
    def corrupt_unit_state!(unit_id) = @unit_states.delete(unit_id)
    def make_reclaimable!(unit_id) = @reclaimable << unit_id

    # Another worker takes the unit from its current owner, with accounting.
    def simulate_reclaim(unit_id, by:) = reclaim!(unit_id, by: by)

    def pending_entry(unit_id)
      @streams.values.flatten.find { |e| e.unit_id == unit_id && e.consumer && !e.acked }
    end

    private

    def retry_budget_exhausted?(state)
      max_requeued = (total_units * requeue_tolerance).ceil
      state["retry_index"] + 1 > max_requeues ||
        (!state["entered_retry"] && @meta["requeued_units_count"].to_i >= max_requeued)
    end

    def reclaim!(unit_id, by:)
      entry = pending_entry(unit_id) or raise ArgumentError, "no pending entry for #{unit_id}"
      state = unit_state!(unit_id)
      previous = entry.consumer
      entry.consumer = by
      entry.delivery_count += 1
      if state["reclaim_count"] + 1 > max_reclaims
        finalize_entry(entry, by, outcome: :failed, duration_ms: 0, reason: "reclaim_budget_exhausted", errors: [])
        return nil
      end
      state["reclaim_count"] += 1
      append("reclaimed", entry, by, "previous_worker_id" => previous)
      touch(by, current_unit: unit_id)
      reservation(entry)
    end

    def finalize_entry(entry, worker_id, outcome:, duration_ms:, reason:, errors:)
      entry.acked = true
      extra = { "outcome" => outcome.to_s, "duration_ms" => duration_ms }
      extra.merge!("reason" => reason, "errors" => errors) if outcome.to_s == "failed"
      append("finalized", entry, worker_id, extra)
      @meta["finalized_count"] = (finalized_count + 1).to_s
      touch(worker_id, current_unit: nil, processed: 1)
    end

    def check_initialization!(token)
      raise LeaseLost, "lease lost" unless token && token == @leader
      raise PreviouslyInitialized, "already initialized before; state gone" if @tombstone && @meta.nil?
      raise AlreadyInitialized, "meta present" if @meta
    end

    def fence!(reservation)
      raise CorruptBuild, "meta missing" unless @meta

      entry = @streams.fetch(reservation.stream).find { |e| e.entry_id == reservation.entry_id }
      unless entry && !entry.acked && entry.consumer == reservation.consumer &&
             entry.delivery_count == reservation.delivery_count
        raise StaleReservation, "ownership of #{reservation.unit_id} moved"
      end

      entry
    end

    def unit_state!(unit_id) = @unit_states.fetch(unit_id) { raise CorruptBuild, "unit_state missing for #{unit_id}" }
    def meta! = @meta || raise(BuildStateMissing, "meta missing")

    def new_entry(unit_id, stream)
      Entry.new(entry_id: "#{now_ms}-#{@next_id += 1}", unit_id: unit_id, unit_type: "file", stream: stream,
                consumer: nil, delivery_count: 0, acked: false)
    end

    def reservation(entry)
      state = unit_state!(entry.unit_id)
      Reservation.new(unit_id: entry.unit_id, unit_type: entry.unit_type, stream: entry.stream,
                      entry_id: entry.entry_id, consumer: entry.consumer, delivery_count: entry.delivery_count,
                      retry_index: state["retry_index"], reclaim_count: state["reclaim_count"])
    end

    def unit_fields(reservation)
      { "unit_id" => reservation.unit_id, "worker_id" => reservation.consumer,
        "retry_index" => reservation.retry_index, "reclaim_count" => reservation.reclaim_count,
        "ownership_generation" => reservation.ownership_generation }
    end

    def append(type, entry, worker_id, extra = {})
      state = unit_state!(entry.unit_id)
      @events << { "type" => type, "unit_id" => entry.unit_id, "worker_id" => worker_id,
                   "retry_index" => state["retry_index"], "reclaim_count" => state["reclaim_count"],
                   "ownership_generation" => 1 + state["retry_index"] + state["reclaim_count"],
                   "at_ms" => now_ms }.merge(extra)
    end

    def touch(worker_id, current_unit:, processed: 0)
      record = @workers[worker_id] ||= { "last_seen" => 0, "current_unit" => nil, "processed" => 0 }
      record.merge!("last_seen" => now_ms, "current_unit" => current_unit,
                    "processed" => record["processed"] + processed)
    end

    def now_ms = (@clock.call * 1000).to_i
  end
end
