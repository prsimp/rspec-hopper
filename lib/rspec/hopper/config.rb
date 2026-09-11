# frozen_string_literal: true

module RSpec
  module Hopper
    # Frozen configuration for the `work` subcommand. Passed explicitly to every
    # collaborator; there is no global.
    WorkConfig = Data.define(
      :build_id, :worker_id, :redis_url,
      :timeout, :max_unit_duration, :max_requeues, :requeue_tolerance, :max_reclaims,
      :processes, :boot, :report_on_exit,
      :ttl, :tombstone_ttl, :init_timeout, :revision,
      :rspec_args, :report_args, :supervised
    ) do
      def self.build(**attrs)
        new(**Config::WORK_DEFAULTS, **attrs)
      end

      def heartbeat_interval
        [timeout / 3.0, 30.0].min
      end
    end

    # Frozen configuration for the `report` subcommand.
    ReportConfig = Data.define(
      :build_id, :redis_url, :timeout, :init_timeout, :inactive_timeout,
      :summary_out, :failed_out, :allow_empty, :min_examples
    ) do
      def self.build(**attrs)
        new(**Config::REPORT_DEFAULTS, **attrs)
      end
    end

    module Config
      WORK_DEFAULTS = {
        build_id: nil, worker_id: nil, redis_url: nil,
        timeout: 180, max_unit_duration: 900, max_requeues: 0, requeue_tolerance: 0.0, max_reclaims: 3,
        processes: 1, boot: :per_process, report_on_exit: false,
        ttl: 14_400, tombstone_ttl: 604_800, init_timeout: 300, revision: nil,
        rspec_args: [], report_args: [], supervised: false
      }.freeze

      REPORT_DEFAULTS = {
        build_id: nil, redis_url: nil, timeout: 1080, init_timeout: 300, inactive_timeout: 300,
        summary_out: nil, failed_out: nil, allow_empty: false, min_examples: 0
      }.freeze
    end
  end
end
