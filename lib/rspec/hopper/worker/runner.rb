# frozen_string_literal: true

require "rspec/core"

module RSpec
  module Hopper
    class Worker
      # The RSpec runner the worker drives. `configure` is inherited unchanged;
      # `run_specs` is replaced so that the reporter lifecycle (`start`,
      # `finish`, `close`) and the per-process suite hooks fire exactly once
      # around the hopper loop instead of around `ordered_example_groups`.
      #
      # Runner#setup is not used: its `ensure world.announce_filters` calls
      # `reporter.abort_with` (an `exit!`) for `--only-failures` before the
      # worker could reject the option, and load-error capture has to be
      # scoped to `load_spec_files` alone. Suite performs those steps itself.
      class Runner < RSpec::Core::Runner
        # @param expected_example_count [Integer] the manifest's total examples
        # @yield [RSpec::Core::Reporter] the real reporter, inside suite hooks
        def run_specs(expected_example_count)
          @configuration.reporter.report(expected_example_count) do |reporter|
            @configuration.with_suite_hooks { yield reporter }
          end
        end
      end
    end
  end
end
