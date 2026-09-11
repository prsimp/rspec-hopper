# frozen_string_literal: true

require "optparse"
require "redis"

module RSpec
  module Hopper
    module CLI
      # `rspec-hopper report`: parses flags into a ReportConfig and runs Report.
      class Report
        # Raised by `parse` for -h/--help; `run` prints usage and returns 0.
        class HelpRequested < StandardError; end

        BANNER = "Usage: rspec-hopper report --build ID --redis URL [options]"

        class << self
          def usage = build_parser({}).to_s

          # Returns a frozen ReportConfig. Build id falls back to HOPPER_BUILD_ID;
          # the Redis URL to HOPPER_REDIS_URL then REDIS_URL.
          def parse(argv, env: ENV)
            opts = {}
            rest = build_parser(opts).parse(argv)
            raise UsageError, "unexpected argument(s): #{rest.join(" ")}" if rest.any?

            opts[:build_id] ||= env["HOPPER_BUILD_ID"]
            opts[:redis_url] ||= env["HOPPER_REDIS_URL"] || env["REDIS_URL"]
            validate!(opts)
            ReportConfig.build(**opts)
          rescue OptionParser::ParseError => e
            raise UsageError, e.message
          end

          def run(argv, out: $stdout, err: $stderr, env: ENV)
            config = parse(argv, env: env)
            redis = Redis.new(url: config.redis_url)
            queue = Queue::RedisStreams.new(redis: redis, build_id: config.build_id)
            Hopper::Report.new(config: config, queue: queue).run(out: out)
          rescue HelpRequested
            out.puts usage
            ExitCode::OK
          rescue UsageError => e
            err.puts "rspec-hopper report: #{e.message}"
            err.puts usage
            ExitCode::INFRASTRUCTURE
          rescue InfrastructureError => e
            err.puts "rspec-hopper report: #{e.message}"
            e.exit_code
          ensure
            redis&.close
          end

          private

          def validate!(opts)
            raise UsageError, "--build ID is required (or set HOPPER_BUILD_ID)" unless opts[:build_id]
            raise UsageError, "--redis URL is required (or set HOPPER_REDIS_URL / REDIS_URL)" unless opts[:redis_url]

            if opts[:allow_empty] && opts.fetch(:min_examples, 0).positive?
              raise UsageError, "--allow-empty cannot be combined with a positive --min-examples"
            end

            %i[timeout init_timeout inactive_timeout min_examples].each do |key|
              raise UsageError, "--#{key.to_s.tr("_", "-")} must not be negative" if opts[key]&.negative?
            end
          end

          def build_parser(opts)
            OptionParser.new(BANNER, 28) do |parser|
              parser.separator ""
              parser.separator "Waits for the build to initialize and complete, then prints the verdict."
              parser.separator ""
              connection_options(parser, opts)
              wait_options(parser, opts)
              output_options(parser, opts)
              verdict_options(parser, opts)
              parser.on_tail("-h", "--help", "show this help") { raise HelpRequested }
            end
          end

          def connection_options(parser, opts)
            parser.on("--build ID", "build id (default: $HOPPER_BUILD_ID)") { |v| opts[:build_id] = v }
            parser.on("--redis URL", "Redis URL (default: $HOPPER_REDIS_URL, then $REDIS_URL)") do |v|
              opts[:redis_url] = v
            end
          end

          def wait_options(parser, opts)
            parser.on("--timeout S", Float, "give up after S seconds (default 1080)") { |v| opts[:timeout] = v }
            parser.on("--init-timeout S", Float, "wait S seconds for initialization (default 300)") do |v|
              opts[:init_timeout] = v
            end
            parser.on("--inactive-timeout S", Float,
                      "give up after S seconds without worker activity (default 300)") do |v|
              opts[:inactive_timeout] = v
            end
          end

          def output_options(parser, opts)
            parser.on("--summary-out PATH", "write the JSON summary to PATH") { |v| opts[:summary_out] = v }
            parser.on("--failed-out PATH", "write failed and never-finalized unit ids to PATH") do |v|
              opts[:failed_out] = v
            end
          end

          def verdict_options(parser, opts)
            parser.on("--fail-on-empty", "zero selected examples is a failure (default)") { opts[:allow_empty] = false }
            parser.on("--allow-empty", "zero selected examples may pass") { opts[:allow_empty] = true }
            parser.on("--min-examples N", Integer, "fail unless at least N examples were selected") do |v|
              opts[:min_examples] = v
            end
          end
        end
      end
    end
  end
end
