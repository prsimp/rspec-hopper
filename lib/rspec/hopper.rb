# frozen_string_literal: true

require "json"

require_relative "hopper/version"
require_relative "hopper/errors"
require_relative "hopper/config"
require_relative "hopper/unit"
require_relative "hopper/reservation"
require_relative "hopper/keys"
require_relative "hopper/manifest"
require_relative "hopper/attempt_log"
require_relative "hopper/queue"
require_relative "hopper/queue/redis_streams"
require_relative "hopper/fingerprint"
require_relative "hopper/example_reset"
require_relative "hopper/example_subset"
require_relative "hopper/worker/buffering_reporter"
require_relative "hopper/worker/heartbeat"
require_relative "hopper/worker/requeue_policy"
require_relative "hopper/worker/runner"
require_relative "hopper/worker/suite"
require_relative "hopper/worker"
require_relative "hopper/report"
require_relative "hopper/ci_env"
require_relative "hopper/supervisor"
require_relative "hopper/cli/report"
require_relative "hopper/cli/formatter_args"
require_relative "hopper/cli/work"
require_relative "hopper/cli"

module RSpec
  # Distributes an RSpec suite across CI workers through Redis Streams.
  module Hopper
    @before_fork_hooks = []
    @after_fork_hooks = []

    class << self
      # Registers a block to run in the parent, once, before any child is forked
      # in `--boot shared` mode. Close connections opened during boot here.
      def before_fork(&block)
        @before_fork_hooks << block
        block
      end

      # Registers a block to run in every child after fork in `--boot shared`
      # mode. The block receives the child's TEST_ENV_NUMBER value ("" or "2".."N").
      def after_fork(&block)
        @after_fork_hooks << block
        block
      end

      # @api private
      attr_reader :before_fork_hooks

      # @api private
      attr_reader :after_fork_hooks

      # @api private
      def reset_hooks!
        @before_fork_hooks = []
        @after_fork_hooks = []
      end
    end
  end
end
