# frozen_string_literal: true

require "rspec/core"
require "shellwords"

module RSpec
  module Hopper
    class Worker
      # Loads the RSpec suite once per process, rejects unsupported options,
      # discovers file units, computes the fingerprint and adopts the build seed.
      # This is the only place that mutates RSpec.configuration.
      class Suite
        RUNNER_OPTIONS = {
          "InitializeProject" => "--init", "PrintVersion" => "--version", "PrintHelp" => "--help",
          "Bisect" => "--bisect", "DRbWithFallback" => "--drb"
        }.freeze

        # Captures `message` notifications while spec files load; that is how
        # `Reporter#notify_non_example_exception` surfaces load errors.
        class LoadErrorCapture
          attr_reader :messages

          def initialize
            @messages = []
            @active = false
          end

          def activate = @active = true
          def deactivate = @active = false

          def message(notification)
            @messages << notification.message.to_s if @active
          end
        end

        attr_reader :rspec_args, :config, :options, :runner, :units, :file_counts, :total_examples, :example_ids,
                    :load_errors, :fingerprint, :file_args

        # @return [Suite] loaded and ready; raises UnsupportedOption or BootError
        def self.load(rspec_args, config:, out: $stdout, err: $stderr)
          new(rspec_args, config: config, out: out, err: err).load
        end

        def initialize(rspec_args, config:, out: $stdout, err: $stderr)
          @rspec_args = Array(rspec_args).map(&:to_s)
          @config = config
          @out = out
          @err = err
          @load_errors = []
          @groups_by_file = {}
        end

        def configuration = RSpec.configuration
        def world = RSpec.world

        def load
          reject_init_option!
          @options = RSpec::Core::ConfigurationOptions.new(rspec_args)
          reject_runner_option!
          @runner = Runner.new(options, configuration, world)
          runner.configure(@err, @out)
          reject_failed_configuration!
          reject_unsupported_configuration!
          normalize_file_args!
          load_spec_files
          describe_loaded_suite
          self
        rescue InfrastructureError
          raise
        rescue StandardError, ScriptError => e
          raise BootError, "#{e.class}: #{e.message}", e.backtrace
        end

        # Modules prepended onto `RSpec::Core::Runner` that define `run_specs`.
        # A prepend on the superclass cannot intercept a method the subclass
        # defines, and the worker's Runner defines `run_specs` itself, so these
        # never run here.
        #
        # @param base [Class] the class to inspect; injectable for specs
        def self.runner_wrappers(base = RSpec::Core::Runner)
          base.ancestors
              .take_while { |mod| !mod.equal?(base) }
              .select { |mod| mod.method_defined?(:run_specs, false) }
              .map { |mod| mod.name || mod.inspect }
        end

        def unit_ids = units.map(&:id)

        # Top-level groups whose file is the unit, in configured order.
        def groups_for(unit_id) = @groups_by_file.fetch(unit_id, [])

        # Selected examples of the unit, including nested groups.
        def examples_for(unit_id) = groups_for(unit_id).flat_map(&:descendant_filtered_examples)

        # Sets the build seed without changing the global ordering strategy:
        # `Configuration#seed=` switches an unforced global ordering to random,
        # which would silently reorder a suite that runs in defined order.
        def adopt_seed(seed)
          return if seed.nil?

          registry = configuration.ordering_registry
          strategy = registry.fetch(:global)
          configuration.seed = seed
          registry.register(:global, strategy) unless registry.fetch(:global).equal?(strategy)
          configuration.seed
        end
        alias seed= adopt_seed

        # Applies the `--format`/`--out` pairs of `args` to the already
        # configured RSpec, for a suite loaded once in a shared-boot parent
        # whose children each need their own formatter output. Other arguments
        # are ignored: the suite already applied them. Pairing follows RSpec's
        # parser: `--out` attaches to the preceding `--format`, or to the
        # default progress formatter when there is none.
        def apply_formatter_args(args)
          _remaining, pairs = CLI::FormatterArgs.split(Array(args).map(&:to_s))
          entries = CLI::FormatterArgs.entries(pairs).map { |formatter, out| out ? [formatter, out] : [formatter] }
          entries.each { |entry| configuration.add_formatter(*entry) }
          entries
        end

        def to_manifest(revision: config.revision)
          Manifest.new(
            total_examples: total_examples, file_counts: file_counts, file_args: file_args,
            fingerprint: fingerprint.value, fingerprint_digests: fingerprint.digests,
            seed: configuration.seed, revision: revision, load_errors: load_errors
          )
        end

        private

        # Everything that depends on the spec files being loaded: instrumentation
        # is installed by then, and the units and fingerprint come from the
        # groups the load produced.
        def describe_loaded_suite
          warn_about_runner_wrappers
          world.announce_filters
          discover_units
          @fingerprint = Fingerprint.compute(configuration: configuration, options: options, example_ids: example_ids,
                                             file_args: file_args, revision: config.revision)
        end

        # The per-example patches such gems install still work — that is what
        # the no-prepend promise is about — so the failure is otherwise silent:
        # spans keep being produced with no session for them to belong to, and
        # the build looks instrumented while reporting nothing.
        def warn_about_runner_wrappers
          wrappers = self.class.runner_wrappers
          return if wrappers.empty?

          @err.puts "[hopper #{config.worker_id}] #{wrappers.join(", ")} wraps " \
                    "RSpec::Core::Runner#run_specs, which rspec-hopper replaces, so that wrapper will not " \
                    "run. Instrumentation that starts there (datadog-ci's test session and module, for " \
                    "one) must be started from a before(:suite) hook and finished in after(:suite): hopper " \
                    "runs those once per worker process. See the README."
          @err.flush if @err.respond_to?(:flush)
        end

        def reject_init_option!
          env_args = ENV["SPEC_OPTS"] ? Shellwords.split(ENV["SPEC_OPTS"]) : []
          return unless (rspec_args + env_args).include?("--init")

          raise UnsupportedOption, unsupported("--init")
        end

        def reject_runner_option!
          runner = options.options[:runner]
          return if runner.nil?

          name = RUNNER_OPTIONS.fetch(runner.class.name.to_s.split("::").last, runner.class.name)
          raise UnsupportedOption, unsupported(name)
        end

        # A `--require` that fails is reported by RSpec while the options are
        # applied, before spec files load; every worker shares the arguments,
        # so it is a boot failure rather than a spec-file load error.
        def reject_failed_configuration!
          return unless world.wants_to_quit || world.rspec_is_quitting

          raise BootError, "RSpec reported an error while applying its options (for example a --require that " \
                           "could not be loaded); see the RSpec output"
        end

        def reject_unsupported_configuration!
          raise UnsupportedOption, unsupported("--bisect") if options.options[:bisect]
          raise UnsupportedOption, unsupported("--drb") if options.options[:drb]
          raise UnsupportedOption, unsupported("--only-failures / --next-failure") if configuration.only_failures?
          raise UnsupportedOption, unsupported("--fail-fast") if configuration.fail_fast
          raise UnsupportedOption, unsupported("--dry-run") if configuration.dry_run?
        end

        def unsupported(name)
          "RSpec option #{name} is not supported by rspec-hopper: every selected unit must reach a final state"
        end

        # RSpec only falls back to `default_path` when `$0` is `rspec`; the
        # worker applies the same default so `rspec-hopper work` with no file
        # arguments runs the spec directory like `rspec` would.
        def normalize_file_args!
          files = Array(options.options[:files_or_directories_to_run]).map(&:to_s)
          files = [configuration.default_path.to_s] if files.empty? && configuration.default_path
          configuration.files_or_directories_to_run = files
          @file_args = files.freeze
        end

        def load_spec_files
          capture = LoadErrorCapture.new
          configuration.reporter.register_listener(capture, :message)
          capture.activate
          begin
            configuration.load_spec_files unless world.wants_to_quit
          rescue SystemExit => e
            capture.messages << "#{e.class} raised while loading spec files" if capture.messages.empty?
          ensure
            capture.deactivate
          end
          return unless world.wants_to_quit || world.rspec_is_quitting

          @load_errors = capture.messages.dup.freeze
          @load_errors = ["RSpec reported a failure while loading spec files"] if @load_errors.empty?
        end

        def discover_units
          world.ordered_example_groups.each do |group|
            next if group.descendant_filtered_examples.empty?

            (@groups_by_file[group.metadata[:file_path]] ||= []) << group
          end
          @file_counts = @groups_by_file.transform_values do |groups|
            groups.sum do |g|
              g.descendant_filtered_examples.size
            end
          end
                                        .freeze
          @units = @file_counts.keys.map { |path| Unit.file(path) }.freeze
          @total_examples = @file_counts.values.sum
          @example_ids = @groups_by_file.values.flatten.flat_map(&:descendant_filtered_examples).map(&:id).sort.freeze
        end
      end
    end
  end
end
