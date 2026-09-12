# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

module HopperSpec
  # Helpers for the integration specs that spawn real `rspec-hopper` processes:
  # Redis-side observation of a build, polling with deadlines instead of bare
  # sleeps, per-example output directories and the consistency invariants
  # every finished build must satisfy. Included into groups tagged
  # `:integration`; every build id handed out is deleted afterwards.
  module Integration
    class WaitTimeout < StandardError; end

    SLOW_UNIT = "./spec/slow_spec.rb"
    HANG_UNIT = "./spec/hang_spec.rb"
    ABORT_UNIT = "./spec/abort_spec.rb"
    FLAKY_UNIT = "./spec/flaky_spec.rb"

    # Reading a build's state from Redis and waiting for it to change.
    module Builds
      def redis_url = HopperSpec::RedisHelper.url

      def redis = @redis ||= HopperSpec::RedisHelper.new_connection

      # The example's own build id, created on first use and deleted afterwards.
      def build_id = @build_id ||= track_build(HopperSpec::RedisHelper.build_id("int"))

      def track_build(id)
        tracked_builds << id
        id
      end

      def tracked_builds = @tracked_builds ||= []

      def queue(id = build_id)
        (@queues ||= {})[id] ||= RSpec::Hopper::Queue::RedisStreams.new(redis: redis, build_id: id)
      end

      def keys_for(id = build_id) = RSpec::Hopper::Keys.new(id)

      def attempt_log(id = build_id) = RSpec::Hopper::AttemptLog.new(queue(id).attempt_events)

      def manifest(id = build_id) = queue(id).manifest

      def workers(id = build_id) = queue(id).workers

      def unit_states(id = build_id) = queue(id).unit_states

      def finalized_count(id = build_id) = queue(id).finalized_count

      def complete?(id = build_id)
        queue(id).complete?
      rescue RSpec::Hopper::BuildStateMissing
        false
      end

      # Raw event hashes of one type, optionally for one unit.
      def events(type, id = build_id, unit_id: nil)
        attempt_log(id).to_a.select { |e| e["type"] == type && (unit_id.nil? || e["unit_id"] == unit_id) }
      end

      # Worker id whose `workers` record says it currently holds `unit_id`.
      def holder_of(unit_id, id = build_id)
        workers(id).find { |_wid, record| record["current_unit"] == unit_id }&.first
      end

      # Worker ids whose record shows no current unit.
      def idle_worker_ids(id = build_id)
        workers(id).select { |_wid, record| record["current_unit"].nil? }.keys
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def epoch_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)

      # Polls the block until it returns a truthy value and returns that value.
      # Raises WaitTimeout with `message` after `timeout` seconds.
      def wait_until(timeout:, interval: 0.05, message: "condition")
        deadline = monotonic + timeout
        loop do
          value = yield
          return value if value

          raise WaitTimeout, "timed out after #{timeout}s waiting for #{message}" if monotonic > deadline

          sleep interval
        end
      end

      def wait_for_holder(unit_id, id = build_id, timeout: 10)
        wait_until(timeout: timeout, message: "a worker to hold #{unit_id}") { holder_of(unit_id, id) }
      end

      def wait_for_ready(id = build_id, timeout: 15)
        wait_until(timeout: timeout, message: "build #{id} to be ready") { queue(id).status.ready? }
      end

      def wait_for_completion(id = build_id, timeout: 30)
        wait_until(timeout: timeout, message: "build #{id} to complete") { complete?(id) }
      end

      def wait_for_event(type, id = build_id, unit_id: nil, timeout: 15)
        wait_until(timeout: timeout, message: "a #{type} event#{" for #{unit_id}" if unit_id}") do
          found = events(type, id, unit_id: unit_id)
          found.any? ? found : nil
        end
      end
    end

    # Spawning `work` and `report` processes and their output files.
    module Processes
      # Spawns `count` workers (ids w1..wN unless `ids` is given) on one fixture.
      # Returns a Hash of worker id => ProcessHandle.
      def spawn_workers(count = 1, fixture:, id: build_id, args: [], env: {}, extra_rspec_args: [], ids: nil)
        ids ||= (1..count).map { |n| "w#{n}" }
        ids.to_h do |wid|
          handle = spawn_worker(fixture: fixture, worker_id: wid, id: id, args: args, env: env,
                                extra_rspec_args: extra_rspec_args)
          [wid, handle]
        end
      end

      def spawn_worker(fixture:, worker_id:, id: build_id, args: [], env: {}, extra_rspec_args: [])
        HopperSpec::Fixtures.spawn_worker(fixture: fixture, build_id: id, worker_id: worker_id, redis_url: redis_url,
                                          args: args, env: env, extra_rspec_args: extra_rspec_args)
      end

      def spawn_report(id = build_id, args: [])
        HopperSpec::Fixtures.spawn_report(build_id: id, redis_url: redis_url, args: args)
      end

      def run_report(id = build_id, args: [], timeout: 60)
        handle = spawn_report(id, args: args)
        handle.wait(timeout: timeout)
        handle
      end

      # Waits for every handle; returns a Hash of worker id => exit code.
      def wait_all(handles, timeout: 60)
        handles.transform_values do |handle|
          handle.wait(timeout: timeout)
          handle.exit_code
        end
      end

      # Non-blocking reap. Returns the Process::Status once the process has
      # exited (recording it on the handle, which only offers a blocking
      # `wait`), nil while it is still running.
      def try_reap(handle)
        return handle.exit_status if handle.reaped?

        pid, status = Process.wait2(handle.pid, Process::WNOHANG)
        return nil unless pid

        handle.instance_variable_set(:@exit_status, status)
        status
      rescue Errno::ECHILD
        nil
      end

      # A fresh directory for formatter output and report summaries, removed
      # after the example.
      def out_dir = @out_dir ||= Dir.mktmpdir("hopper-int").tap { |d| out_dirs << d }

      def out_dirs = @out_dirs ||= []

      def out_path(name) = File.join(out_dir, name)

      def state_dir = @state_dir ||= HopperSpec::Fixtures.state_dir

      def state_env = { "HOPPER_FIXTURE_STATE_DIR" => state_dir }

      # `--format json --out <path>` for one worker's formatter output.
      def json_format_args(name) = ["--format", "json", "--out", out_path(name)]

      def read_json(path)
        raise "expected #{path} to exist" unless File.exist?(path)

        JSON.parse(File.read(path))
      end

      # Example id => status from a JSON formatter file (empty when never written).
      def formatter_examples(path)
        return {} unless File.exist?(path)

        read_json(path).fetch("examples").to_h { |e| [e["id"], e["status"]] }
      end

      def summary_path = out_path("summary.json")

      def summary = read_json(summary_path)
    end

    # What every finished build must satisfy, whatever happened to its workers.
    module Invariants
      # Every manifest unit has exactly one `finalized` event, finalized_count
      # equals total_units, every remaining key has a positive TTL, each unit's
      # `unit_state.reclaim_count` equals its number of `reclaimed` events and
      # every unit-scoped event's ownership_generation is derived correctly.
      def expect_consistent_build(id = build_id)
        man = manifest(id)
        expect(man).not_to be_nil, "build #{id} has no manifest"
        log = attempt_log(id)
        expect_finalized_exactly_once(log, man)
        expect(finalized_count(id)).to eq(man.total_units)
        expect_positive_ttls(id)
        expect_reclaim_counts_match(log, man, unit_states(id))
        expect(log.select(&:unit_scoped?).reject(&:consistent_generation?)).to be_empty
      end

      def expect_finalized_exactly_once(log, man)
        man.unit_ids.each do |unit_id|
          finals = log.finalized_events(unit_id)
          expect(finals.size).to eq(1), "#{unit_id} has #{finals.size} finalized events: #{finals.inspect}"
        end
      end

      def expect_positive_ttls(id = build_id)
        ttls = HopperSpec::RedisHelper.ttls(redis, id)
        expect(ttls).not_to be_empty
        expect(ttls.reject { |_k, ttl| ttl.positive? }).to be_empty
      end

      def expect_reclaim_counts_match(log, man, states)
        expect(states.keys).to match_array(man.unit_ids)
        man.unit_ids.each do |unit_id|
          reclaims = log.reclaim_counts.fetch(unit_id, 0)
          expect(states.fetch(unit_id)["reclaim_count"]).to eq(reclaims),
                                                            "#{unit_id}: unit_state.reclaim_count != reclaimed events"
        end
      end
    end

    include Builds
    include Processes
    include Invariants

    def integration_cleanup!
      tracked_builds.each { |id| HopperSpec::RedisHelper.delete_build(redis, id) }
      tracked_builds.clear
      out_dirs.each { |d| FileUtils.rm_rf(d) }
      @redis&.close
      @redis = nil
    end
  end
end

RSpec.configure do |config|
  config.include HopperSpec::Integration, :integration
  config.after(:each, :integration) { integration_cleanup! }
end
