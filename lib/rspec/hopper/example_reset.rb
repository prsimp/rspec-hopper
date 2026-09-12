# frozen_string_literal: true

require "rspec/core"

module RSpec
  module Hopper
    # Makes completed examples rerunnable in the same process.
    #
    # rspec-core does not expose a per-example reset: `@exception` is set once
    # and never cleared by `run`, `finish` reports failure whenever it is
    # present, and the ExecutionResult in metadata is mutated in place. This is
    # the one sanctioned touch of Example internals (see the product spec,
    # "Retry state isolation"). It changes no method resolution, so it cannot
    # collide with gems that prepend onto Example.
    module ExampleReset
      # Pinned after a run under bare rspec-core; the contract spec fails loudly
      # if a patch release adds state we would have to reset too.
      EXPECTED_IVARS = %i[
        @clock @example_block @example_group_class @example_group_instance @exception @id @metadata @reporter
      ].freeze

      module_function

      # Resets every selected example in the given top-level groups and all of
      # their descendants. Returns the number of examples reset.
      def reset(example_groups)
        Array(example_groups).sum do |group|
          group.descendants.sum { |descendant| reset_examples(descendant.filtered_examples) }
        end
      end

      # Resets exactly the given examples (an example unit's single example).
      # Returns the number of examples reset.
      def reset_examples(examples)
        Array(examples).each { |example| reset_example(example) }.size
      end

      def reset_example(example)
        example.instance_variable_set(:@exception, nil)
        example.metadata[:execution_result] = RSpec::Core::Example::ExecutionResult.new
        example
      end
    end
  end
end
