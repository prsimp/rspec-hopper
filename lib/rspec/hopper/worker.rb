# frozen_string_literal: true

require "json"
require_relative "worker/runner"

module RSpec
  module Hopper
    # The RSpec adapter: loads the suite, joins or initializes the build, pulls
    # units, runs each through `ExampleGroup.run`, decides requeue from the
    # execution results and forwards final attempts to the formatters.
    class Worker
      POLL_INTERVAL = 0.5

      Outcome = Data.define(:duration_ms, :escaped, :stale)

      # Internal: unwinds to `run` with an exit code after the error was recorded and printed.
      class Abort < StandardError
        attr_reader :code

        def initialize(code)
          @code = code
          super("worker exiting with #{code}")
        end
      end

      # Matches redis-rb connection failures without requiring the redis gem.
      REDIS_ERROR = Module.new do
        def self.===(error)
          error.class.ancestors.any? { |a| a.name == "Redis::BaseConnectionError" }
        end
      end

      attr_reader :config, :suite, :queue

      # @param queue_factory [#call] returns the Queue; called after the suite boots
      # @param suite [Suite, nil] a pre-loaded suite (shared boot mode); the
      #   `--format`/`--out` pairs in `config.rspec_args` are applied to it
      # @param clock [#call] monotonic seconds
      # @param sleeper [#call] sleeps for the given seconds
      # @param aborter [#call] receives an exit code; defaults to `exit!`
      # @param ppid [#call] the parent pid, checked between units when supervised
      def initialize(config:, queue_factory:, suite: nil, out: $stdout, err: $stderr, clock: nil, sleeper: nil,
                     aborter: nil, ppid: nil)
        @config = config
        @queue_factory = queue_factory
        @suite = suite
        @out = out
        @err = err
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
        @aborter = aborter
        @ppid = ppid || -> { Process.ppid }
        @parent_pid = @ppid.call
      end

      def worker_id = config.worker_id
      def build_id = config.build_id

      # @return [Integer] exit code: 0 on build completion, 2 on infrastructure failure
      def run
        phase(:boot) do
          if @suite
            @suite.apply_formatter_args(config.rspec_args)
          else
            @suite = Suite.load(config.rspec_args, config: config, out: @out, err: @err)
          end
        end
        phase(:redis) { @queue = @queue_factory.call }
        manifest = phase(:init) { join_build }
        phase(:init) do
          check_fingerprint(manifest)
          suite.adopt_seed(manifest.seed)
        end
        suite.runner.run_specs(manifest.total_examples) { |reporter| work_loop(reporter) }
        ExitCode::OK
      rescue Abort => e
        e.code
      end

      private

      # --- initialization ---------------------------------------------------

      def join_build
        deadline = @clock.call + config.init_timeout
        loop do
          status = queue.status
          return joined if status.ready?
          raise InitFailed.new("build #{build_id} failed to initialize", load_errors: recorded_load_errors(status)) if
            status.init_failed?
          raise PreviouslyInitialized, previously_initialized_message if status.tombstone && !status.present?

          token = queue.acquire_leader(worker_id)
          if token
            manifest = publish(token)
            return manifest if manifest
          else
            raise BuildNeverInitialized, "build never initialized (waited #{config.init_timeout}s)" if
              @clock.call >= deadline

            @sleeper.call(POLL_INTERVAL)
          end
        end
      end

      def joined
        manifest = queue.manifest
        raise BuildStateMissing, "build #{build_id} state is missing" if manifest.nil?

        say "joined build #{build_id} (#{manifest.total_units} units, #{manifest.total_examples} examples)"
        manifest
      end

      def publish(token)
        manifest = suite.to_manifest
        if suite.load_errors.any?
          queue.fail_initialization(token: token, manifest: manifest)
          raise InitFailed.new("build #{build_id} failed to initialize", load_errors: suite.load_errors)
        end
        queue.initialize_build(token: token, manifest: manifest, unit_ids: suite.unit_ids)
        say "initialized build #{build_id} (#{manifest.total_units} units, #{manifest.total_examples} examples)"
        queue.manifest
      rescue LeaseLost, AlreadyInitialized
        nil
      end

      def recorded_load_errors(status)
        JSON.parse(status.meta&.fetch("load_errors", nil) || "[]")
      rescue JSON::ParserError
        []
      end

      def previously_initialized_message
        "build #{build_id} was previously initialized; its state is gone. Choose a new build id."
      end

      def check_fingerprint(manifest)
        return if manifest.fingerprint.nil? || manifest.fingerprint == suite.fingerprint.value

        raise FingerprintMismatch,
              Fingerprint::Mismatch.explain(suite.fingerprint, manifest.fingerprint, manifest.fingerprint_digests)
      end

      # --- the loop -----------------------------------------------------------

      def work_loop(reporter)
        loop do
          phase(:execution) do
            raise InfrastructureError, "RSpec wants to quit (a before(:suite) hook failed?)" if world.wants_to_quit
          end
          reservation = phase(:reserve) { queue.reclaim_lost(worker_id) || queue.reserve(worker_id) }
          if reservation
            execute(reservation, reporter)
          else
            phase(:reserve) { queue.touch_liveness(worker_id) }
          end
          break if phase(:reserve) { queue.complete? }

          check_parent!
        end
      end

      def check_parent!
        return unless config.supervised
        return if @ppid.call == @parent_pid

        alert "parent gone; exiting"
        raise Abort, ExitCode::INFRASTRUCTURE
      end

      def execute(reservation, reporter)
        unit_id = reservation.unit_id
        groups = suite.groups_for(unit_id)
        examples = suite.examples_for(unit_id)
        buffer = BufferingReporter.new
        outcome = phase(:execution, unit_id: unit_id) do
          raise InfrastructureError, "unit #{unit_id} is not part of this worker's suite" if groups.empty?

          run_groups(groups, buffer, reservation)
        end
        decision = RequeuePolicy.decide(examples, escaped: outcome.escaped)
        phase(:execution, unit_id: unit_id) do
          if decision.unexecuted.any? && outcome.escaped.nil?
            raise InfrastructureError, "#{decision.unexecuted.size} example(s) of #{unit_id} did not run"
          end

          settle(reservation, decision, buffer, outcome.duration_ms, reporter)
        end
        return unless outcome.escaped

        alert "#{outcome.escaped.class} escaped an example in #{unit_id}; the unit was finalized as failed"
      end

      def run_groups(groups, buffer, reservation)
        ExampleReset.reset(groups)
        heartbeat = Heartbeat.new(queue: queue, reservation: reservation, config: config, err: @err, clock: @clock,
                                  aborter: @aborter, worker_id: worker_id)
        started = @clock.call
        escaped = nil
        heartbeat.start
        begin
          groups.each { |group| group.run(buffer) }
        rescue *RequeuePolicy::NON_REQUEUEABLE => e
          escaped = e
        ensure
          heartbeat.stop
        end
        Outcome.new(duration_ms: ((@clock.call - started) * 1000).round, escaped: escaped, stale: heartbeat.stale?)
      end

      def settle(reservation, decision, buffer, duration_ms, reporter)
        unit_id = reservation.unit_id
        operation = decision.requeue_candidate? ? :requeue : :finalize
        begin
          return if requeued?(reservation, decision, duration_ms)
        rescue StaleReservation
          buffer.discard
          queue.record_stale_rejected(reservation, operation: operation)
          say "reservation for #{unit_id} is stale; result discarded"
          return
        end
        phase(:formatter, unit_id: unit_id) { buffer.replay(reporter) }
      end

      # Finalizes or requeues; true when the unit was requeued (buffer dropped).
      def requeued?(reservation, decision, duration_ms)
        unit_id = reservation.unit_id
        if decision.passed?
          queue.finalize(reservation, outcome: :passed, duration_ms: duration_ms)
        elsif decision.final_failure?
          queue.finalize(reservation, outcome: :failed, duration_ms: duration_ms, reason: "test_failure",
                                      errors: decision.errors)
        else
          result = queue.requeue(reservation, duration_ms: duration_ms, failure_summary: decision.summary,
                                              errors: decision.errors)
          if result.requeued?
            say "Retrying #{unit_id} (retry #{result.retry_index} of #{config.max_requeues}; " \
                "next attempt #{result.retry_index + 1}): #{decision.summary}"
            return true
          end
        end
        false
      end

      # --- error handling -----------------------------------------------------

      # Runs a block for a phase; any failure is recorded, printed and turned
      # into an Abort with the infrastructure exit code.
      def phase(name, unit_id: nil)
        yield
      rescue Abort, StaleReservation, *RequeuePolicy::NON_REQUEUEABLE
        raise
      rescue BuildStateMissing => e
        fail_with(e, phase: "redis", unit_id: unit_id, message: "build state for #{build_id} is gone: #{e.message}")
      rescue CorruptBuild => e
        fail_with(e, phase: "redis", unit_id: unit_id, message: "build #{build_id} is corrupt: #{e.message}")
      rescue REDIS_ERROR => e
        error = RedisUnreachable.new("Redis unreachable: #{e.class}: #{e.message}")
        error.set_backtrace(e.backtrace)
        fail_with(error, phase: "redis", unit_id: unit_id, record: false)
      rescue InitFailed => e
        fail_with(e, phase: name.to_s, unit_id: unit_id, message: init_failed_message(e))
      rescue InfrastructureError => e
        fail_with(e, phase: name.to_s, unit_id: unit_id)
      rescue StandardError => e
        fail_with(e, phase: name.to_s, unit_id: unit_id,
                     message: "#{e.class}: #{e.message}\n  #{Array(e.backtrace).first(5).join("\n  ")}")
      end

      def fail_with(error, phase:, unit_id: nil, message: error.message, record: true)
        alert message
        record_worker_error(error, phase: phase, unit_id: unit_id) if record
        raise Abort, ExitCode::INFRASTRUCTURE
      end

      def record_worker_error(error, phase:, unit_id:)
        return if queue.nil?

        queue.record_worker_error(worker_id: worker_id, phase: phase, error: error, unit_id: unit_id)
      rescue StandardError => e
        alert "could not record worker error: #{e.class}: #{e.message}"
      end

      def init_failed_message(error)
        lines = ["#{error.message}; spec files could not be loaded:"]
        lines.concat(error.load_errors.map(&:to_s))
        lines.join("\n")
      end

      # --- output -------------------------------------------------------------

      def world = RSpec.world

      def say(message) = @out.puts("[hopper #{worker_id}] #{message}")

      def alert(message) = @err.puts("[hopper #{worker_id}] #{message}")
    end
  end
end
