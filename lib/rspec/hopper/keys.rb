# frozen_string_literal: true

module RSpec
  module Hopper
    # Redis key names for one build. The braces are a Redis Cluster hash tag so
    # every key of a build shares a slot.
    class Keys
      LIVE = %w[units units:priority attempts meta unit_state workers].freeze
      ALL = (LIVE + %w[leader exists]).freeze
      CONSUMER_GROUP = "workers"

      attr_reader :build_id, :prefix

      def initialize(build_id)
        @build_id = build_id
        @prefix = "hopper:{#{build_id}}:"
      end

      def pattern = "#{@prefix}*"
      def units = key("units")
      def units_priority = key("units:priority")
      def attempts = key("attempts")
      def meta = key("meta")
      def unit_state = key("unit_state")
      def workers = key("workers")
      def leader = key("leader")
      def exists = key("exists")

      def key(name) = "#{@prefix}#{name}"

      # Full key for a short stream name carried in a Reservation.
      def stream(short) = key(short)

      def live = LIVE.map { |n| key(n) }
      def all = ALL.map { |n| key(n) }
    end
  end
end
