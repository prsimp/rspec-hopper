# frozen_string_literal: true

module RSpec
  module Hopper
    # Process exit codes. Precedence between workers is semantic, not numeric:
    # INFRASTRUCTURE beats ABORTED beats OK.
    module ExitCode
      OK = 0
      TEST_FAILURE = 1
      INFRASTRUCTURE = 2
      INCOMPLETE = 3
      ABORTED = 4
    end

    class Error < StandardError; end

    # Anything that makes the worker exit 2.
    class InfrastructureError < Error
      def exit_code = ExitCode::INFRASTRUCTURE
    end

    class BootError < InfrastructureError; end
    class RedisUnreachable < InfrastructureError; end
    class BuildNeverInitialized < InfrastructureError; end

    class InitFailed < InfrastructureError
      attr_reader :load_errors

      def initialize(message = "build initialization failed", load_errors: [])
        @load_errors = load_errors
        super(message)
      end
    end

    class PreviouslyInitialized < InfrastructureError; end
    class AlreadyInitialized < InfrastructureError; end
    class LeaseLost < InfrastructureError; end
    class FingerprintMismatch < InfrastructureError; end
    class UnsupportedOption < InfrastructureError; end
    class SharedBootWithoutHook < InfrastructureError; end
    class ForkUnavailable < InfrastructureError; end
    class BuildStateMissing < InfrastructureError; end
    class CorruptBuild < InfrastructureError; end
    class UsageError < InfrastructureError; end

    # Raised by queue mutations when ownership of the reservation has moved.
    # Not an infrastructure failure: the worker discards its result and moves on.
    class StaleReservation < Error; end

    # Size-capped JSON error payloads recorded in the attempt log.
    module ErrorPayload
      MESSAGE_BYTES = 4096
      BACKTRACE_LINES = 20
      TOTAL_BYTES = 65_536

      module_function

      def from_exception(error, example_id: nil, description: nil)
        {
          "example_id" => example_id,
          "description" => description,
          "class" => error.class.name,
          "message" => truncate(error.message.to_s, MESSAGE_BYTES),
          "backtrace" => (error.backtrace || []).first(BACKTRACE_LINES)
        }
      end

      # Drops trailing entries until the JSON fits, appending a marker for how
      # many were dropped.
      def cap(errors)
        kept = errors.dup
        dropped = 0
        while kept.any? && JSON.generate(kept).bytesize > TOTAL_BYTES
          kept.pop
          dropped += 1
        end
        kept << { "truncated" => dropped } if dropped.positive?
        kept
      end

      def truncate(string, bytes)
        return string if string.bytesize <= bytes

        "#{string.byteslice(0, bytes - 3).scrub("")}..."
      end
    end
  end
end
