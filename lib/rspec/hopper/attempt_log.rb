# frozen_string_literal: true

module RSpec
  module Hopper
    # Append-only stream of typed lifecycle events, and the queries that run
    # over it. Events are the string-keyed Hashes returned by
    # `queue.attempt_events`, in stream order.
    class AttemptLog
      include Enumerable

      TYPES = %w[delivered reclaimed requeued abandoned finalized stale_rejected worker_error].freeze
      UNIT_SCOPED_TYPES = (TYPES - %w[worker_error]).freeze
      # Events that record which worker currently holds a unit.
      OWNERSHIP_TYPES = %w[delivered reclaimed].freeze

      # Thin wrapper over one event Hash.
      class Event
        attr_reader :raw

        def initialize(raw)
          @raw = raw.transform_keys(&:to_s).freeze
        end

        def type = raw["type"]
        def unit_id = raw["unit_id"]
        def worker_id = raw["worker_id"]
        def retry_index = raw["retry_index"]
        def reclaim_count = raw["reclaim_count"]
        def ownership_generation = raw["ownership_generation"]
        def at_ms = raw["at_ms"]

        def [](key) = raw[key.to_s]
        def to_h = raw

        def unit_scoped? = UNIT_SCOPED_TYPES.include?(type) && !unit_id.nil?
        def finalized? = type == "finalized"
        def passed? = finalized? && raw["outcome"] == "passed"
        def failed? = finalized? && raw["outcome"] == "failed"

        # The derived-counter invariant every unit-scoped event must satisfy.
        def consistent_generation?
          ownership_generation == 1 + retry_index.to_i + reclaim_count.to_i
        end
      end

      attr_reader :events

      def initialize(events)
        @events = events.map { |e| e.is_a?(Event) ? e : Event.new(e) }.freeze
      end

      def each(&) = events.each(&)
      def to_a = events.map(&:to_h)
      def size = events.size
      def empty? = events.empty?

      # Unit ids in order of first appearance in the log.
      def unit_ids = by_unit.keys

      # Units whose last `finalized` event is failed.
      def failed
        by_unit.filter_map do |unit_id, unit_events|
          last = last_finalized(unit_events)
          next unless last&.failed?

          { unit_id: unit_id, reason: last["reason"], worker_id: last.worker_id, errors: last["errors"] || [] }
        end
      end

      # Units with at least one `requeued` event whose final outcome is passed.
      # A unit reclaimed after worker death and then passing is not flaky.
      def flaky
        by_unit.filter_map do |unit_id, unit_events|
          unit_id if unit_events.any? { |e| e.type == "requeued" } && last_finalized(unit_events)&.passed?
        end
      end

      # Manifest units with no `finalized` event, with the worker that last held
      # each (from its latest `delivered` or `reclaimed` event).
      def never_finalized(unit_ids)
        unit_ids.filter_map do |unit_id|
          unit_events = by_unit.fetch(unit_id, [])
          next if unit_events.any?(&:finalized?)

          holder = unit_events.reverse.find { |e| OWNERSHIP_TYPES.include?(e.type) }
          { unit_id: unit_id, last_worker_id: holder&.worker_id }
        end
      end

      def abandoned
        by_unit.filter_map { |unit_id, unit_events| unit_id if unit_events.any? { |e| e.type == "abandoned" } }
      end

      # unit id -> highest retry_index seen in its `requeued` events.
      def retry_counts
        by_unit.filter_map do |unit_id, unit_events|
          requeues = unit_events.select { |e| e.type == "requeued" }
          [unit_id, requeues.map { |e| e.retry_index.to_i }.max] if requeues.any?
        end.to_h
      end

      # unit id -> number of `reclaimed` events.
      def reclaim_counts
        by_unit.filter_map do |unit_id, unit_events|
          count = unit_events.count { |e| e.type == "reclaimed" }
          [unit_id, count] if count.positive?
        end.to_h
      end

      def worker_errors = raw_of_type("worker_error")
      def stale_rejections = raw_of_type("stale_rejected")

      def finalized_events(unit_id)
        by_unit.fetch(unit_id, []).select(&:finalized?).map(&:to_h)
      end

      def exactly_one_finalized?(unit_ids)
        unit_ids.all? { |unit_id| finalized_events(unit_id).size == 1 }
      end

      private

      def raw_of_type(type) = events.select { |e| e.type == type }.map(&:to_h)

      def last_finalized(unit_events) = unit_events.reverse.find(&:finalized?)

      # Unit-scoped events grouped by unit, keys in first-appearance order.
      def by_unit
        @by_unit ||= events.select(&:unit_scoped?).group_by(&:unit_id).freeze
      end
    end
  end
end
