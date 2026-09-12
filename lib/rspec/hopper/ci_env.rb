# frozen_string_literal: true

require "socket"

module RSpec
  module Hopper
    # Infers a build id and worker id from common CI environment variables when
    # `--build`/`--worker` are omitted. This is the gem's only CI-vendor
    # awareness. The gem's own variables (HOPPER_BUILD_ID, HOPPER_WORKER_ID) are
    # consulted first by the CLI and always win.
    module CIEnv
      Vendor = Data.define(:name, :detect, :build_vars, :worker_vars, :build_id, :worker_id)

      # Vendor table. `build_vars`/`worker_vars` document what is read; the
      # lambdas derive the ids. `detect` names the variable whose presence
      # identifies the vendor.
      VENDORS = [
        Vendor.new(
          name: "CircleCI", detect: "CIRCLECI",
          build_vars: %w[CIRCLE_WORKFLOW_ID CIRCLE_BUILD_NUM], worker_vars: %w[CIRCLE_NODE_INDEX],
          build_id: ->(env) { present(env["CIRCLE_WORKFLOW_ID"]) || present(env["CIRCLE_BUILD_NUM"]) },
          worker_id: ->(env) { present(env["CIRCLE_NODE_INDEX"]) }
        ),
        Vendor.new(
          name: "Buildkite", detect: "BUILDKITE",
          build_vars: %w[BUILDKITE_BUILD_ID], worker_vars: %w[BUILDKITE_PARALLEL_JOB],
          build_id: ->(env) { present(env["BUILDKITE_BUILD_ID"]) },
          worker_id: ->(env) { present(env["BUILDKITE_PARALLEL_JOB"]) }
        ),
        Vendor.new(
          name: "GitHub Actions", detect: "GITHUB_ACTIONS",
          build_vars: %w[GITHUB_RUN_ID GITHUB_RUN_ATTEMPT], worker_vars: [],
          build_id: lambda { |env|
            run = present(env["GITHUB_RUN_ID"]) or next nil
            "#{run}-#{present(env["GITHUB_RUN_ATTEMPT"]) || "1"}"
          },
          worker_id: ->(_env) {}
        ),
        Vendor.new(
          name: "GitLab CI", detect: "GITLAB_CI",
          build_vars: %w[CI_PIPELINE_ID], worker_vars: %w[CI_NODE_INDEX],
          build_id: ->(env) { present(env["CI_PIPELINE_ID"]) },
          worker_id: ->(env) { present(env["CI_NODE_INDEX"]) }
        )
      ].freeze

      # Documentation table for the README: vendor name, detection variable,
      # build-id variables, worker-id variables.
      VARIABLES = VENDORS.map { |v| [v.name, v.detect, v.build_vars, v.worker_vars] }.freeze

      module_function

      # @return [String, nil] the inferred build id, or nil when no supported
      #   CI vendor is detected.
      def build_id(env = ENV)
        vendor = detect(env) or return nil
        vendor.build_id.call(env)
      end

      # @return [String, nil] the inferred worker id, or nil when the vendor
      #   has no standard parallel-index variable (GitHub Actions) or no vendor
      #   is detected. Callers fall back to {default_worker_id}.
      def worker_id(env = ENV)
        vendor = detect(env) or return nil
        vendor.worker_id.call(env)
      end

      # @return [Vendor, nil]
      def detect(env = ENV)
        VENDORS.find { |v| present(env[v.detect]) }
      end

      # Unique enough for one machine at one moment; used when neither a flag,
      # HOPPER_WORKER_ID, nor a CI variable names the worker.
      def default_worker_id(hostname: Socket.gethostname, pid: Process.pid)
        "#{hostname}-#{pid}"
      end

      def present(value)
        return nil if value.nil?

        value = value.to_s.strip
        value.empty? ? nil : value
      end
    end
  end
end
