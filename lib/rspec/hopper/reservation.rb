# frozen_string_literal: true

module RSpec
  module Hopper
    # The opaque handle for an in-flight stream entry. Every mutation of the
    # entry is fenced on (stream, entry_id, consumer, delivery_count).
    Reservation = Data.define(
      :unit_id, :unit_type, :stream, :entry_id, :consumer, :delivery_count,
      :retry_index, :reclaim_count
    ) do
      def unit = Unit.new(id: unit_id, type: unit_type)

      # Logical ownership generation across stream-entry replacement on retry.
      # Recorded in events, never compared to a limit.
      def ownership_generation = 1 + retry_index + reclaim_count
    end
  end
end
