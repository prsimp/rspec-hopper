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
        attr_reader :reservation, :abandoned_at, :renewals

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

            wait(interval)
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
          :renewed
        rescue StaleReservation
          @stale = true
          :stale
        end

        def abandon!(elapsed)
          return :abandoned if @abandoned_at

          @abandoned_at = elapsed
          @queue.record_abandoned(@reservation, elapsed_ms: (elapsed * 1000).round)
          :abandoned
        rescue StaleReservation
          @stale = true
          :stale
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
