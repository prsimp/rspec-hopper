# frozen_string_literal: true

module RSpec
  module Hopper
    # The `--processes N` parent. Forks N children (each a standalone worker
    # with worker id `<worker>.<n>` and its own TEST_ENV_NUMBER), forwards INT
    # and TERM to them, waits for all of them, and exits per the precedence
    # rules: 2 if any child failed on infrastructure, else 4 if any child
    # aborted a hung unit, else 0 -- or, with --report-on-exit, the report's
    # exit code unless a child exited 2.
    class Supervisor
      FORWARDED_SIGNALS = %w[INT TERM].freeze

      # @param worker_class [#new] `Worker` by default; must accept
      #   `config:, queue_factory:, suite:, out:, err:` and respond to `#run`.
      # @param suite_loader [#call] `(rspec_args, config:, out:, err:) -> suite`
      #   used once in the parent for `--boot shared`.
      # @param report_runner [#call] `(args, out:, err:) -> Integer`
      # @param queue_factory_for [#call] `(config) -> lambda` building a queue.
      # @param fork [#call] `Process.fork` (with block) replacement for tests.
      def initialize(config:, out: $stdout, err: $stderr, worker_class: nil, suite_loader: nil,
                     report_runner: nil, queue_factory_for: nil, fork: Process.method(:fork),
                     fork_available: Process.respond_to?(:fork), env: ENV)
        @config = config
        @out = out
        @err = err
        @worker_class = worker_class
        @suite_loader = suite_loader
        @report_runner = report_runner
        @queue_factory_for = queue_factory_for
        @fork = fork
        @fork_available = fork_available
        @env = env
        @children = {} # pid => n
        @statuses = {} # n => Process::Status
      end

      # @return [Integer] exit code
      def run
        return run_inline if @config.processes == 1
        unless @fork_available
          raise ForkUnavailable, "--processes #{@config.processes} needs fork, which this platform lacks"
        end

        remaining, formatter_pairs = CLI::FormatterArgs.split(@config.rspec_args)
        announce_formatter_output(formatter_pairs)
        suite = @config.boot == :shared ? load_shared_suite(remaining) : nil
        with_signal_forwarding do
          1.upto(@config.processes) { |number| start_child(number, remaining, formatter_pairs, suite) }
          wait_for_children
        end
        exit_code
      rescue InfrastructureError => e
        log(e.message)
        e.exit_code
      end

      # Children write their formatter output to files, so nothing here prints
      # an RSpec summary per process; the verdict comes from `report`.
      def announce_formatter_output(formatter_pairs)
        return unless CLI::FormatterArgs.defaults_needed?(formatter_pairs)

        log("formatter output: #{CLI::FormatterArgs::DEFAULT_DIR}/ " \
            "(the build verdict comes from `rspec-hopper report`)")
      end

      # The value of TEST_ENV_NUMBER for child `number` (1-based): "" for the
      # first, then "2".."N", matching parallel_tests.
      def self.env_number(number) = number == 1 ? "" : number.to_s

      def child_worker_id(number) = "#{@config.worker_id}.#{number}"

      # The config child `number` runs with; public so specs can assert on it.
      def child_config(number, remaining, formatter_pairs)
        env_number = self.class.env_number(number)
        worker_id = child_worker_id(number)
        child_args = CLI::FormatterArgs.for_child(formatter_pairs, env_number, label: worker_id)
        @config.with(
          worker_id: worker_id, supervised: true, processes: 1,
          rspec_args: (child_args + remaining).freeze
        )
      end

      private

      def run_inline
        worker_class.new(config: @config, queue_factory: queue_factory_for.call(@config), out: @out, err: @err).run
      end

      def load_shared_suite(remaining)
        @env.delete("TEST_ENV_NUMBER")
        suite = suite_loader.call(remaining, config: @config, out: @out, err: @err)
        unless RSpec::Hopper.after_fork_hooks.any?
          raise SharedBootWithoutHook,
                "--boot shared needs at least one RSpec::Hopper.after_fork hook: the suite was booted once " \
                "with TEST_ENV_NUMBER unset, so each child must re-derive every value computed from it " \
                "(database name, Redis db, ports, paths). Register a hook or use --boot per-process."
        end
        RSpec::Hopper.before_fork_hooks.each(&:call)
        suite
      end

      def start_child(number, remaining, formatter_pairs, suite)
        config = child_config(number, remaining, formatter_pairs)
        env_number = self.class.env_number(number)
        pid = @fork.call { run_child(config, env_number, suite) }
        @children[pid] = number
        log("started #{config.worker_id} (pid #{pid}, TEST_ENV_NUMBER=#{env_number.inspect})")
      end

      def run_child(config, env_number, suite)
        # SYSTEM_DEFAULT, not DEFAULT: Ruby's own default handling for INT and
        # TERM raises Interrupt/SignalException, which prints a stack trace per
        # child before re-signalling. A forwarded signal would therefore bury
        # the run in N backtraces, and an Interrupt raised inside a unit would
        # be caught as a non-requeueable failure rather than stopping the
        # child. The OS default ends the child silently with the same wait
        # status, which is what the parent reports.
        FORWARDED_SIGNALS.each { |sig| trap(sig, "SYSTEM_DEFAULT") }
        @env["TEST_ENV_NUMBER"] = env_number
        RSpec::Hopper.after_fork_hooks.each { |hook| hook.call(env_number) } if @config.boot == :shared
        kwargs = { config: config, queue_factory: queue_factory_for.call(config), out: @out, err: @err }
        kwargs[:suite] = suite unless suite.nil?
        # `exit`, not `exit!`: RSpec formatters may rely on at_exit handlers. An
        # exception escaping the worker ends the child with status 1, which the
        # parent treats as an infrastructure failure.
        exit(worker_class.new(**kwargs).run)
      end

      def wait_for_children
        @children.each do |pid, number|
          _, status = Process.wait2(pid)
          @statuses[number] = status
          log("#{child_worker_id(number)} (pid #{pid}) #{describe(status)}")
        rescue Errno::ECHILD
          @statuses[number] = nil
          log("#{child_worker_id(number)} (pid #{pid}) was already reaped; treating as failed")
        end
      end

      def with_signal_forwarding
        previous = FORWARDED_SIGNALS.to_h { |sig| [sig, trap(sig) { forward(sig) }] }
        yield
      ensure
        previous&.each { |sig, handler| trap(sig, handler || "DEFAULT") }
      end

      def forward(sig)
        @children.each_key do |pid|
          next if @statuses.key?(@children[pid])

          Process.kill(sig, pid)
        rescue Errno::ESRCH
          nil
        end
      end

      def exit_code
        codes = @statuses.values.map { |status| status&.exitstatus }
        return ExitCode::INFRASTRUCTURE if codes.any? { |c| ![ExitCode::OK, ExitCode::ABORTED].include?(c) }

        aborted = codes.include?(ExitCode::ABORTED)
        return aborted ? ExitCode::ABORTED : ExitCode::OK unless @config.report_on_exit

        log("a child aborted a hung unit (exit 4); the verdict comes from report") if aborted
        report_runner.call(@config.report_args, out: @out, err: @err)
      end

      def describe(status)
        return "exited #{status.exitstatus}" if status.exited?
        return "killed by SIG#{Signal.signame(status.termsig)}" if status.signaled?

        "stopped with #{status.inspect}"
      end

      def log(message)
        @err.puts "[hopper #{@config.worker_id}] #{message}"
        @err.flush if @err.respond_to?(:flush)
      end

      def worker_class = @worker_class || Worker

      def suite_loader
        @suite_loader || ->(args, config:, out:, err:) { Worker::Suite.load(args, config: config, out: out, err: err) }
      end

      def report_runner
        @report_runner || ->(args, out:, err:) { CLI::Report.run(args, out: out, err: err) }
      end

      def queue_factory_for
        @queue_factory_for || ->(config) { CLI::Work.queue_factory(config) }
      end
    end
  end
end
