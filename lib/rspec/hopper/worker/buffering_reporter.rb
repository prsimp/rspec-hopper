# frozen_string_literal: true

module RSpec
  module Hopper
    class Worker
      # Records every notification RSpec sends while a unit's example groups
      # run, so that the worker can replay them to the real reporter exactly
      # once for a final attempt or discard them for a requeued or stale one.
      # Suite lifecycle notifications (`start`, `finish`, `close`, `report`) are
      # deliberately not defined: they belong to the outer runner.
      class BufferingReporter
        BUFFERED = %i[
          example_group_started example_group_finished
          example_started example_finished example_passed example_failed example_pending
          message publish notify_non_example_exception deprecation
        ].freeze

        attr_reader :events

        def initialize
          @events = []
        end

        BUFFERED.each do |name|
          define_method(name) do |*args, **kwargs|
            @events << [name, args, kwargs]
            nil
          end
        end

        # RSpec consults this after every failure; the worker never fails fast.
        def fail_fast_limit_met? = false

        def size = @events.size
        def empty? = @events.empty?

        # Sends every recorded notification to `real`, in original order.
        def replay(real)
          @events.each { |name, args, kwargs| real.public_send(name, *args, **kwargs) }
          discard
          self
        end

        def discard
          @events = []
          self
        end
      end
    end
  end
end
