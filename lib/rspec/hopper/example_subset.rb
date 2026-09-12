# frozen_string_literal: true

require "rspec/core"

module RSpec
  module Hopper
    # Runs a subset of an example group's selected examples through the public
    # `ExampleGroup.run`, which is how example units execute one example while
    # its file's context hooks still fire around it.
    #
    # `ExampleGroup.run` takes what to run from `RSpec.world.filtered_examples`
    # and memoizes `descendant_filtered_examples` per group, which decides
    # whether a group's `before(:context)`/`after(:context)` hooks run at all.
    # Both are private to rspec-core. This is the second sanctioned touch of
    # RSpec internals, granted for Phase 2 alongside ExampleReset: it swaps two
    # pieces of state around one `run` and restores them afterwards, changes no
    # method resolution, and is guarded by a contract spec pinned to 3.12-3.13.
    module ExampleSubset
      # The group-level memo that `ExampleGroup.run` consults through
      # `descendant_filtered_examples`; the contract spec pins its presence.
      MEMO_IVAR = :@descendant_filtered_examples

      # Class-level instance variables of a run example group, pinned under
      # bare rspec-core by the contract spec so new group state in a future
      # release fails loudly rather than silently escaping the swap.
      EXPECTED_GROUP_IVARS = %i[
        @before_context_ivars @children @currently_executing_a_context_hook @descendant_filtered_examples
        @examples @hooks @metadata @parent_groups @superclass_metadata @user_metadata
      ].freeze

      module_function

      # Narrows `root` and its descendants to `examples` for the duration of
      # the block. Groups with none of them selected run no examples and no
      # context hooks. Returns the block's value.
      def scoped(root, examples)
        groups = root.descendants
        saved = groups.to_h { |group| [group, [world.filtered_examples[group], memo(group)]] }
        groups.each do |group|
          world.filtered_examples[group] = saved[group].first.select { |example| examples.include?(example) }
          group.instance_variable_set(MEMO_IVAR, nil)
        end
        yield
      ensure
        saved&.each do |group, (filtered, memo)|
          world.filtered_examples[group] = filtered
          group.instance_variable_set(MEMO_IVAR, memo)
        end
      end

      def memo(group) = group.instance_variable_get(MEMO_IVAR)

      def world = RSpec.world
    end
  end
end
