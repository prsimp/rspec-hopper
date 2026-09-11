# frozen_string_literal: true

module RSpec
  module Hopper
    # Storage-agnostic queue protocol. See docs/DESIGN.md for the full contract.
    # The only adapter is Queue::RedisStreams. No RSpec knowledge lives here.
    module Queue
      Status = Data.define(:state, :tombstone, :meta) do
        def ready? = state == "ready"
        def init_failed? = state == "init_failed"
        def present? = !meta.nil?
      end

      RequeueResult = Data.define(:status, :retry_index) do
        def requeued? = status == :requeued
        def finalized? = status == :finalized
      end

      PHASES = %w[boot init reserve execution redis formatter].freeze
      REASONS = %w[test_failure retry_budget_exhausted reclaim_budget_exhausted].freeze
      OUTCOMES = %i[passed failed].freeze
    end
  end
end
