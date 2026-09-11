# frozen_string_literal: true

require_relative "work/parser"

module RSpec
  module Hopper
    module CLI
      # `rspec-hopper work`: parses the gem's own flags into a frozen WorkConfig
      # and hands everything else to RSpec, then runs one worker inline or a
      # Supervisor for `--processes N`.
      module Work
        module_function

        # @return [Integer] exit code
        def run(argv, out: $stdout, err: $stderr, env: ENV, worker_class: nil, supervisor_class: nil)
          config = parse(argv, env: env)
          worker_class ||= Worker
          if config.processes == 1
            worker_class.new(config: config, queue_factory: queue_factory(config), out: out, err: err).run
          else
            (supervisor_class || Supervisor).new(config: config, out: out, err: err, worker_class: worker_class).run
          end
        rescue HelpRequested => e
          out.puts e.text
          ExitCode::OK
        rescue UsageError => e
          err.puts "rspec-hopper work: #{e.message}"
          err.puts "Run `rspec-hopper work --help` for usage."
          ExitCode::INFRASTRUCTURE
        rescue Redis::BaseConnectionError => e
          err.puts "rspec-hopper work: Redis unreachable at #{config&.redis_url}: #{e.message}"
          ExitCode::INFRASTRUCTURE
        rescue InfrastructureError => e
          err.puts "rspec-hopper work: #{e.message}"
          e.exit_code
        end

        # @param argv [Array<String>] arguments after the `work` subcommand
        # @param env [#[]] environment for --build/--worker/--redis fallbacks
        # @return [WorkConfig]
        # @raise [UsageError, HelpRequested]
        def parse(argv, env: ENV) = Parser.parse(argv, env: env)

        # A zero-argument lambda opening Redis on first call, so the suite can
        # boot before any connection exists and children open their own.
        def queue_factory(config)
          lambda do
            Queue::RedisStreams.new(
              redis: Redis.new(url: config.redis_url), build_id: config.build_id,
              ttl: config.ttl, tombstone_ttl: config.tombstone_ttl, timeout: config.timeout,
              max_requeues: config.max_requeues, requeue_tolerance: config.requeue_tolerance,
              max_reclaims: config.max_reclaims
            )
          end
        end
      end
    end
  end
end
