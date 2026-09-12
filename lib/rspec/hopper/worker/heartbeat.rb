# frozen_string_literal: true

module RSpec
  module Hopper
    class Worker
      # Keeps a reservation alive while its unit executes. Runs in a thread
      # that renews the reservation every `config.heartbeat_interval` seconds.
      # After `max_unit_duration` it records `abandoned` once and stops
      # renewing; after a further `timeout` it aborts the whole process, since
      # the hung test thread cannot be interrupted safely.
      class Heartbeat
        # How long to wait before retrying a renewal that failed on a Redis
        # connection error, capped by the normal interval.
        RETRY_INTERVAL = 1.0

        attr_reader :reservation, :abandoned_at, :renewals, :renewal_failures

        # @param clock [#call] monotonic seconds
        # @param sleeper [#call, nil] waits for the given seconds; nil uses an
        #   interruptible wait so `stop` returns promptly
        # @param aborter [#call] receives the exit code; defaults to `exit!`
        def initialize(queue:, reservation:, config:, err: $stderr, clock: nil, sleeper: nil, aborter: nil,
                       worker_id: config.worker_id)
          @queue = queue
          @reservation = reservation
          @config = config
          @err = err
          @worker_id = worker_id
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          @sleeper = sleeper
          @aborter = aborter || ->(code) { Kernel.exit!(code) }
          @signal = Thread::Queue.new
          @stopped = false
          @stale = false
          @abandoned_at = nil
          @renewals = 0
          @renewal_failures = 0
        end

        def interval = @config.heartbeat_interval
        def stale? = @stale
        def abandoned? = !@abandoned_at.nil?
        def running? = !@thread.nil? && @thread.alive?

        # Marks the unit as started at `now` without spawning the thread, so
        # the loop can be driven through `tick`.
        def prime(now = @clock.call)
          @started_at = @last_renewal = now
          self
        end

        def start
          prime
          @thread = Thread.new { run_loop }
          @thread.name = "hopper-heartbeat" if @thread.respond_to?(:name=)
          self
        end

        def stop
          @stopped = true
          @signal << :stop
          @thread&.join
          self
        end

        # One step of the loop, at time `now`. Public so it can be driven
        # without a thread. Returns what happened.
        def tick(now)
          return :stopped if @stopped

          elapsed = now - @started_at
          if elapsed >= abort_after
            abort!
            :aborted
          elsif elapsed >= @config.max_unit_duration
            abandon!(elapsed)
          elsif now - @last_renewal >= interval
            renew!(now)
          else
            :idle
          end
        end

        private

        def abort_after = @config.max_unit_duration + @config.timeout

        def run_loop
          until @stopped
            result = tick(@clock.call)
            break if %i[aborted stale].include?(result)

            wait(result == :retrying ? [RETRY_INTERVAL, interval].min : interval)
          end
        end

        def wait(seconds)
          if @sleeper
            @sleeper.call(seconds)
          else
            @signal.pop(timeout: seconds)
          end
        end

        def renew!(now)
          @queue.heartbeat(@reservation)
          @last_renewal = now
          @renewals += 1
          recovered if @renewal_failures.positive?
          :renewed
        rescue StaleReservation
          @stale = true
          :stale
        rescue REDIS_ERROR => e
          failed_renewal(e, now)
        end

        # A connection error is not yet a lost unit: the reservation stays this
        # worker's until `timeout` passes without a renewal. Retry until then
        # rather than killing a worker that is running tests fine, and give up
        # once the entry is reclaimable, when carrying on would only let a
        # sibling run the unit while this process still owns its output.
        def failed_renewal(error, now)
          @renewal_failures += 1
          raise error if now - @last_renewal >= @config.timeout

          if @renewal_failures == 1
            warn_heartbeat "heartbeat failed (#{error.class}: #{error.message}); " \
                           "retrying for up to #{@config.timeout}s"
          end
          :retrying
        end

        def recovered
          warn_heartbeat "heartbeat recovered after #{@renewal_failures} failed " \
                         "#{@renewal_failures == 1 ? "attempt" : "attempts"}"
          @renewal_failures = 0
        end

        def warn_heartbeat(message)
          @err.puts "[hopper #{@worker_id}] #{@reservation.unit_id}: #{message}"
          @err.flush if @err.respond_to?(:flush)
        end

        # The `abandoned` event is a warning, not a terminal state, so a Redis
        # error while recording it retries on the next tick and never ends the
        # worker: the abort at `max_unit_duration + timeout` still fires.
        def abandon!(elapsed)
          return :abandoned if @abandoned_at

          @queue.record_abandoned(@reservation, elapsed_ms: (elapsed * 1000).round)
          @abandoned_at = elapsed
          :abandoned
        rescue StaleReservation
          @stale = true
          :stale
        rescue REDIS_ERROR
          :retrying
        end

        def abort!
          @err.puts "[hopper #{@worker_id}] Aborting worker: #{@reservation.unit_id} exceeded " \
                    "#{format_seconds(@config.max_unit_duration)}s"
          @err.flush if @err.respond_to?(:flush)
          @aborter.call(ExitCode::ABORTED)
        end

        def format_seconds(value)
          value == value.to_i ? value.to_i : value
        end
      end
    end
  end
end
