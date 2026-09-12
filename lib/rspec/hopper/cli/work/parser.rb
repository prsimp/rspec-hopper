# frozen_string_literal: true

require "optparse"

module RSpec
  module Hopper
    module CLI
      module Work
        # OptionParser for `rspec-hopper work`. Consumes the gem's own flags
        # and passes every other argument, and everything after `--`, to RSpec
        # in the original order.
        class Parser
          BOOT_MODES = { "per-process" => :per_process, "shared" => :shared }.freeze
          POSITIVE = %i[timeout max_unit_duration ttl tombstone_ttl init_timeout].freeze
          NON_NEGATIVE = %i[max_requeues max_reclaims].freeze

          BANNER = <<~BANNER
            Usage: rspec-hopper work --build ID --worker WID --redis URL [options] [rspec args...] -- [files...]

            Every argument the gem does not recognise, and everything after `--`, is
            passed to RSpec unchanged. --build, --worker and --redis fall back to
            HOPPER_BUILD_ID, HOPPER_WORKER_ID and HOPPER_REDIS_URL/REDIS_URL, then to
            CI environment variables (CircleCI, Buildkite, GitHub Actions, GitLab).
          BANNER

          # @return [WorkConfig]
          # @raise [UsageError, HelpRequested]
          def self.parse(argv, env: ENV) = new(env: env).parse(argv)

          def initialize(env: ENV)
            @env = env
            @opts = {}
          end

          def parse(argv)
            rspec_args = extract(argv)
            resolve_ids
            validate_ids!
            validate_numbers!
            WorkConfig.build(
              **@opts, rspec_args: rspec_args.freeze,
                       report_args: ["--build", @opts[:build_id], "--redis", @opts[:redis_url]].freeze
            )
          end

          private

          # Consumes the gem's flags from argv; returns everything else.
          def extract(argv)
            own, tail = split_on_double_dash(argv)
            rest = []
            parser = option_parser
            begin
              parser.order!(own) { |positional| rest << positional }
            rescue OptionParser::InvalidOption => e
              e.recover(own)
              rest << own.shift
              retry
            rescue OptionParser::ParseError => e
              raise UsageError, e.message
            end
            rest + tail
          end

          def split_on_double_dash(argv)
            index = argv.index("--")
            return [argv.dup, []] if index.nil?

            [argv[0...index], argv[index..]]
          end

          def option_parser
            OptionParser.new do |o|
              o.banner = BANNER
              identity_options(o)
              unit_options(o)
              policy_options(o)
              process_options(o)
              lifetime_options(o)
              o.separator ""
              o.on("-h", "--help", "show this help") { raise HelpRequested, o.help }
            end
          end

          def identity_options(opt)
            opt.separator ""
            opt.separator "Identity:"
            opt.on("--build ID", "build id shared by every worker of one CI run") { |v| @opts[:build_id] = v }
            opt.on("--worker WID", "this worker's id, unique within the build") { |v| @opts[:worker_id] = v }
            opt.on("--redis URL", "Redis URL") { |v| @opts[:redis_url] = v }
            opt.on("--revision SHA", "revision string mixed into the suite fingerprint") { |v| @opts[:revision] = v }
          end

          def unit_options(opt)
            opt.separator ""
            opt.separator "Work units:"
            opt.on("--unit TYPE", UNIT_TYPES, "what one queue entry is: file (default) or example") do |v|
              @opts[:unit_type] = v
            end
          end

          def policy_options(opt)
            opt.separator ""
            opt.separator "Requeue and timeout policy:"
            opt.on("--timeout SECONDS", Numeric, "missed-heartbeat window before a unit is reclaimable (180)") do |v|
              @opts[:timeout] = v
            end
            opt.on("--max-unit-duration SECONDS", Numeric, "abandon a unit running longer than this (900)") do |v|
              @opts[:max_unit_duration] = v
            end
            opt.on("--max-requeues N", Integer, "max retries of any one unit (0)") { |v| @opts[:max_requeues] = v }
            opt.on("--requeue-tolerance R", Float, "fraction of units allowed to retry (0)") do |v|
              @opts[:requeue_tolerance] = v
            end
            opt.on("--max-reclaims N", Integer, "reclaims from dead workers before a unit fails (3)") do |v|
              @opts[:max_reclaims] = v
            end
          end

          def process_options(opt)
            opt.separator ""
            opt.separator "Process parallelism:"
            opt.on("--processes N", Integer, "fork N worker processes on this machine (1)") do |v|
              @opts[:processes] = v
            end
            opt.on("--boot MODE", BOOT_MODES.keys, "per-process (default) or shared") do |v|
              @opts[:boot] = BOOT_MODES[v]
            end
            opt.on("--report-on-exit", "parent runs `report` after all children exit") do
              @opts[:report_on_exit] = true
            end
          end

          def lifetime_options(opt)
            opt.separator ""
            opt.separator "Redis lifetimes:"
            opt.on("--ttl SECONDS", Numeric, "inactivity TTL of live build keys (14400)") { |v| @opts[:ttl] = v }
            opt.on("--tombstone-ttl SECONDS", Numeric, "lifetime of the build tombstone (604800)") do |v|
              @opts[:tombstone_ttl] = v
            end
            opt.on("--init-timeout SECONDS", Numeric, "wait this long for build initialization (300)") do |v|
              @opts[:init_timeout] = v
            end
          end

          def resolve_ids
            @opts[:build_id] ||= CIEnv.present(@env["HOPPER_BUILD_ID"]) || CIEnv.build_id(@env)
            @opts[:worker_id] ||= CIEnv.present(@env["HOPPER_WORKER_ID"]) || CIEnv.worker_id(@env) ||
                                  CIEnv.default_worker_id
            @opts[:redis_url] ||= CIEnv.present(@env["HOPPER_REDIS_URL"]) || CIEnv.present(@env["REDIS_URL"])
          end

          def validate_ids!
            raise UsageError, "--build is required (or set HOPPER_BUILD_ID)" unless @opts[:build_id]
            raise UsageError, "--redis is required (or set HOPPER_REDIS_URL or REDIS_URL)" unless @opts[:redis_url]
          end

          def validate_numbers!
            POSITIVE.each { |key| check(key, "must be positive", &:positive?) }
            NON_NEGATIVE.each { |key| check(key, "must not be negative") { |v| !v.negative? } }
            check(:processes, "must be at least 1") { |v| v >= 1 }
            check(:requeue_tolerance, "must be between 0 and 1") { |v| (0.0..1.0).cover?(v) }
          end

          def check(key, requirement)
            return unless @opts.key?(key)
            return if yield(@opts[key])

            raise UsageError, "--#{key.to_s.tr("_", "-")} #{requirement}, got #{@opts[key]}"
          end
        end
      end
    end
  end
end
