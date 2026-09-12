# frozen_string_literal: true

require "fileutils"
require "json"
require "redis"

module RSpec
  module Hopper
    # Produces the one authoritative verdict for a build. Never loads spec files,
    # never writes to Redis, and knows nothing about RSpec.
    class Report
      VERDICTS = %w[passed failed incomplete init_failed missing expired unreachable].freeze

      Outcome = Data.define(:verdict, :exit_code, :headline, :details) do
        def initialize(verdict:, exit_code:, headline:, details: [])
          super
        end
      end

      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      EPOCH_MS = -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }

      attr_reader :config, :queue, :summary

      # `clock` (monotonic seconds) budgets --timeout and --init-timeout.
      # `wall_clock` (epoch ms) is compared with Redis-stamped `ready_at` and
      # `workers.last_seen` for --inactive-timeout.
      def initialize(config:, queue:, clock: MONOTONIC, sleeper: ->(s) { sleep(s) }, poll_interval: 1.0,
                     wall_clock: EPOCH_MS)
        @config = config
        @queue = queue
        @clock = clock
        @sleeper = sleeper
        @poll_interval = poll_interval
        @wall_clock = wall_clock
        @summary = nil
      end

      # Runs the wait phases, prints a human summary, writes the configured
      # output files and returns the exit code.
      def run(out: $stdout)
        reset
        outcome = evaluate
        @summary = build_summary(outcome)
        write_outputs
        print_outcome(out, outcome)
        outcome.exit_code
      end

      def attempt_log = @attempt_log ||= AttemptLog.new(@events)

      private

      def reset
        @started = @clock.call
        @state = nil
        @manifest = nil
        @finalized_count = nil
        @workers = {}
        @events = []
        @attempt_log = nil
      end

      def evaluate
        status = wait_for_status
        return missing unless status
        return expired unless status.present?

        @state = status.state
        @manifest = Manifest.from_meta(status.meta)
        return init_failed if status.init_failed?

        incomplete_reason = wait_for_completion
        collect_events
        incomplete_reason ? incomplete(*incomplete_reason) : verdict
      rescue Redis::BaseConnectionError, RedisUnreachable => e
        Outcome.new(verdict: "unreachable", exit_code: ExitCode::INFRASTRUCTURE,
                    headline: "redis unreachable: #{e.message}")
      rescue BuildStateMissing
        expired
      end

      # --- wait phases -------------------------------------------------------

      def wait_for_status
        loop do
          status = @queue.status
          return status if status.present? || status.tombstone
          return nil if elapsed >= config.init_timeout

          @sleeper.call(@poll_interval)
        end
      end

      # Returns nil once every unit is finalized, otherwise why it gave up:
      # `[:timeout]` or `[:inactive, idle_seconds]`.
      def wait_for_completion
        loop do
          @finalized_count = @queue.finalized_count
          @workers = @queue.workers
          return nil if @finalized_count >= @manifest.total_units
          return [:timeout] if elapsed >= config.timeout

          idle = idle_seconds
          return [:inactive, idle] if idle > config.inactive_timeout

          @sleeper.call(@poll_interval)
        end
      end

      def collect_events
        @events = @queue.attempt_events
        @attempt_log = nil
      end

      def elapsed = @clock.call - @started

      # Seconds since the later of ready_at and the most recent worker liveness.
      def idle_seconds
        stamps = [@manifest.ready_at, *@workers.values.map { |w| w["last_seen"] }].compact
        return 0.0 if stamps.empty?

        (@wall_clock.call - stamps.max) / 1000.0
      end

      # --- outcomes ------------------------------------------------------------

      def missing
        Outcome.new(verdict: "missing", exit_code: ExitCode::INFRASTRUCTURE,
                    headline: "build #{config.build_id} never initialized " \
                              "(no manifest or tombstone after #{config.init_timeout}s)")
      end

      def expired
        Outcome.new(verdict: "expired", exit_code: ExitCode::INCOMPLETE,
                    headline: "build #{config.build_id} was previously initialized; its state is gone " \
                              "(expired or evicted)")
      end

      def init_failed
        collect_events
        Outcome.new(verdict: "init_failed", exit_code: ExitCode::INCOMPLETE,
                    headline: "build #{config.build_id} failed to initialize: " \
                              "#{@manifest.load_errors.size} spec file load error(s)",
                    details: @manifest.load_errors)
      end

      # Built only after collect_events so the never-finalized list is current.
      def incomplete(cause, idle = nil)
        headline = if cause == :timeout
                     "incomplete: #{gap} after #{config.timeout}s (--timeout)"
                   else
                     "incomplete: workers inactive for #{idle.round}s " \
                       "(--inactive-timeout #{config.inactive_timeout}s); #{gap}"
                   end
        Outcome.new(verdict: "incomplete", exit_code: ExitCode::INCOMPLETE, headline: headline,
                    details: never_finalized_lines)
      end

      def verdict
        if @manifest.empty? && !config.allow_empty
          Outcome.new(verdict: "failed", exit_code: ExitCode::TEST_FAILURE,
                      headline: "#{count(@manifest.file_args.size, "file")} given, 0 examples selected",
                      details: @manifest.file_args)
        elsif @manifest.total_examples < config.min_examples
          Outcome.new(verdict: "failed", exit_code: ExitCode::TEST_FAILURE,
                      headline: "#{@manifest.total_examples} examples selected, " \
                                "fewer than --min-examples #{config.min_examples}")
        elsif attempt_log.failed.any?
          Outcome.new(verdict: "failed", exit_code: ExitCode::TEST_FAILURE,
                      headline: "#{attempt_log.failed.size} of #{@manifest.total_units} units failed",
                      details: failed_lines)
        else
          Outcome.new(verdict: "passed", exit_code: ExitCode::OK, headline: "passed")
        end
      end

      def gap = "#{@finalized_count} of #{@manifest.total_units} units finalized"

      def count(number, noun) = "#{number} #{number == 1 ? noun : "#{noun}s"}"

      def never_finalized
        return [] unless @manifest

        attempt_log.never_finalized(@manifest.unit_ids)
      end

      def never_finalized_lines
        never_finalized.map do |entry|
          holder = entry[:last_worker_id] ? "last worker #{entry[:last_worker_id]}" : "never delivered"
          "never finalized: #{entry[:unit_id]} (#{holder})"
        end
      end

      def failed_lines
        attempt_log.failed.map do |entry|
          line = "failed: #{entry[:unit_id]} (#{entry[:reason]}, worker #{entry[:worker_id]})"
          first = entry[:errors].find { |e| e.is_a?(Hash) && e["message"] }
          line += " #{first["class"]}: #{first["message"].lines.first.to_s.strip}" if first
          line
        end
      end

      # --- output --------------------------------------------------------------

      def print_outcome(out, outcome)
        out.puts "rspec-hopper report: build #{config.build_id}: #{outcome.verdict}"
        out.puts "  #{outcome.headline}"
        out.puts "  units: #{totals_line}"
        outcome.details.each { |line| out.puts "  #{line}" }
        print_log_notes(out)
      end

      def totals_line
        return "unknown (no manifest)" unless @manifest

        finalized = @finalized_count.nil? ? "" : ", #{@finalized_count} finalized"
        "#{@manifest.total_units} #{@manifest.unit_type} units total#{finalized}; " \
          "examples: #{@manifest.total_examples} selected"
      end

      def print_log_notes(out)
        return unless @manifest

        flaky = attempt_log.flaky
        out.puts "  flaky (passed after requeue): #{flaky.join(", ")}" if flaky.any?
        abandoned = attempt_log.abandoned
        out.puts "  abandoned (exceeded --max-unit-duration): #{abandoned.join(", ")}" if abandoned.any?
        attempt_log.worker_errors.each do |e|
          out.puts "  worker error: #{e["worker_id"]} #{e["phase"]} #{e["class"]}: #{e["message"]}"
        end
      end

      def build_summary(outcome)
        {
          "build_id" => config.build_id,
          "state" => @state,
          "verdict" => outcome.verdict,
          "exit_code" => outcome.exit_code,
          "message" => outcome.headline,
          "total_units" => @manifest&.total_units,
          "unit_type" => @manifest&.unit_type,
          "total_examples" => @manifest&.total_examples,
          "finalized_count" => @finalized_count,
          **log_summary,
          "workers" => @workers,
          **manifest_summary
        }
      end

      def log_summary
        {
          "failed" => attempt_log.failed.map { |h| h.transform_keys(&:to_s) },
          "flaky" => attempt_log.flaky,
          "never_finalized" => never_finalized.map { |h| h.transform_keys(&:to_s) },
          "abandoned" => attempt_log.abandoned,
          "retry_counts" => attempt_log.retry_counts,
          "reclaim_counts" => attempt_log.reclaim_counts,
          "worker_errors" => attempt_log.worker_errors,
          "stale_rejections" => attempt_log.stale_rejections.size
        }
      end

      def manifest_summary
        {
          "load_errors" => @manifest&.load_errors || [],
          "file_args" => @manifest&.file_args || [],
          "seed" => @manifest&.seed,
          "fingerprint" => @manifest&.fingerprint,
          "revision" => @manifest&.revision
        }
      end

      def write_outputs
        write_file(config.summary_out, "#{JSON.pretty_generate(@summary)}\n") if config.summary_out
        return unless config.failed_out

        ids = @summary["failed"].map { |f| f["unit_id"] } + @summary["never_finalized"].map { |n| n["unit_id"] }
        write_file(config.failed_out, ids.map { |id| "#{id}\n" }.join)
      end

      def write_file(path, content)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
    end
  end
end
