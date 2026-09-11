# frozen_string_literal: true

module RSpec
  module Hopper
    class Worker
      # Decides, from the execution results of a unit's selected examples,
      # whether a failed attempt may be requeued. An attempt is a requeue
      # candidate only if every failure in it is requeueable.
      module RequeuePolicy
        # These never justify a retry; one anywhere in the unit makes the
        # attempt final. They also escape `Example#run` rather than being
        # recorded on the example, so the worker passes them in as `escaped`.
        NON_REQUEUEABLE = [SystemExit, Interrupt, SignalException, NoMemoryError].freeze

        Decision = Data.define(:status, :failed_examples, :unexecuted, :escaped) do
          def passed? = status == :passed
          def requeue_candidate? = status == :requeue_candidate
          def final_failure? = status == :final_failure

          def failure_count = failed_examples.size + (escaped ? 1 : 0)

          def summary = RequeuePolicy.failure_summary(failure_count)

          # Size-capped error payload for the attempt log.
          def errors
            entries = failed_examples.flat_map do |example|
              RequeuePolicy.exceptions_of(example).map do |exception|
                ErrorPayload.from_exception(exception, example_id: example.id, description: example.full_description)
              end
            end
            entries << escaped_payload if escaped
            ErrorPayload.cap(entries)
          end

          private

          def escaped_payload
            example = unexecuted.find { |ex| ex.execution_result.started_at }
            ErrorPayload.from_exception(escaped, example_id: example&.id, description: example&.full_description)
          end
        end

        module_function

        # @param examples [Array<RSpec::Core::Example>] the unit's selected examples
        # @param escaped [Exception, nil] an exception that escaped `ExampleGroup.run`
        def decide(examples, escaped: nil)
          failed = examples.select { |ex| ex.execution_result.status == :failed }
          unexecuted = examples.select { |ex| ex.execution_result.status.nil? }
          Decision.new(status: status_for(failed, escaped), failed_examples: failed, unexecuted: unexecuted,
                       escaped: escaped)
        end

        def status_for(failed, escaped)
          return :final_failure if escaped
          return :passed if failed.empty?
          return :requeue_candidate if failed.all? { |ex| exceptions_of(ex).all? { |e| requeueable?(e) } }

          :final_failure
        end

        def requeueable?(exception)
          NON_REQUEUEABLE.none? { |klass| exception.is_a?(klass) }
        end

        # Every exception behind a failed example, with aggregate errors
        # (`MultipleExceptionError` and friends) flattened.
        def exceptions_of(example)
          flatten(example.execution_result.exception || example.exception)
        end

        def flatten(exception)
          return [] if exception.nil?
          return [exception] unless exception.respond_to?(:all_exceptions)

          nested = exception.all_exceptions.flat_map { |e| flatten(e) }
          nested.empty? ? [exception] : nested
        end

        def failure_summary(count)
          "#{count} failure#{"s" unless count == 1}"
        end
      end
    end
  end
end
