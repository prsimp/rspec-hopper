# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module HopperSpec
  # Spawns real `rspec-hopper work` / `report` processes against the fixture
  # suites under spec/fixtures/suites. Output goes to files, never pipes, so a
  # chatty child cannot deadlock the test; every spawned process is killed in
  # an `after` hook if a spec forgets to.
  module Fixtures
    ROOT = File.expand_path("../..", __dir__)
    SUITES = File.join(ROOT, "spec", "fixtures", "suites")
    LIB = File.join(ROOT, "lib")
    EXE = File.join(ROOT, "exe", "rspec-hopper")
    GEMFILE = File.join(ROOT, "Gemfile")

    class ProcessTimeout < StandardError; end

    # A spawned process with its captured output.
    class ProcessHandle
      attr_reader :pid, :command, :exit_status

      def initialize(pid:, command:, dir:)
        @pid = pid
        @command = command
        @dir = dir
        @exit_status = nil
      end

      def stdout_path = File.join(@dir, "stdout")
      def stderr_path = File.join(@dir, "stderr")
      def stdout = File.exist?(stdout_path) ? File.read(stdout_path) : ""
      def stderr = File.exist?(stderr_path) ? File.read(stderr_path) : ""

      # @return [Integer, nil] exit status, nil if not yet waited or signaled
      def exit_code = exit_status&.exitstatus
      def signaled? = exit_status&.signaled? || false
      def termsig = exit_status&.termsig
      def reaped? = !exit_status.nil?

      def alive?
        return false if reaped?

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end

      # Sends a signal to the process (or, with group: true, to its whole
      # process group: the supervisor and its forked children). EPERM is
      # treated like ESRCH: the pid or group is no longer ours to signal, and
      # raising here from the shared cleanup hook would fail every later
      # example in the run.
      def kill(sig, group: false)
        Process.kill(sig, group ? -pid : pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      # Polls for exit. On timeout kills the process group and raises with the
      # captured output.
      def wait(timeout: 60)
        return exit_status if reaped?

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          pid_waited, status = Process.wait2(pid, Process::WNOHANG)
          if pid_waited
            @exit_status = status
            return status
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            terminate
            raise ProcessTimeout, "#{command.join(" ")} did not exit within #{timeout}s\n" \
                                  "--- stdout ---\n#{stdout}\n--- stderr ---\n#{stderr}"
          end
          sleep 0.05
        end
      rescue Errno::ECHILD
        @exit_status ||= nil
        nil
      end

      # Kills the process group and reaps the process. Idempotent.
      def terminate
        kill("KILL", group: true)
        kill("KILL")
        unless reaped?
          begin
            _, @exit_status = Process.wait2(pid)
          rescue Errno::ECHILD
            nil
          end
        end
        self
      end

      def close
        terminate
        FileUtils.rm_rf(@dir)
      end
    end

    module_function

    def live = (@live ||= [])
    def state_dirs = (@state_dirs ||= [])

    def exe = EXE
    def root = ROOT

    def path(name)
      dir = File.join(SUITES, name)
      raise ArgumentError, "no fixture suite named #{name.inspect} under #{SUITES}" unless File.directory?(dir)

      dir
    end

    # A fresh directory for fixtures that share state across processes via
    # HOPPER_FIXTURE_STATE_DIR. Removed by {cleanup!}.
    def state_dir
      dir = Dir.mktmpdir("hopper-state")
      state_dirs << dir
      dir
    end

    # @param fixture [String] fixture suite name (chdir for the worker)
    # @param args [Array<String>] extra `work` flags
    # @param extra_rspec_args [Array<String>] passed through to RSpec
    # @param env [Hash] extra environment (nil values unset a variable)
    def spawn_worker(fixture:, build_id:, worker_id:, redis_url:, args: [], env: {}, extra_rspec_args: [])
      spawn(
        ["work", "--build", build_id, "--worker", worker_id, "--redis", redis_url, *args, *extra_rspec_args],
        chdir: path(fixture), env: env
      )
    end

    def spawn_report(build_id:, redis_url:, args: [], env: {}, chdir: ROOT)
      spawn(["report", "--build", build_id, "--redis", redis_url, *args], chdir: chdir, env: env)
    end

    def run_and_wait(timeout: 60, **spawn_kwargs)
      handle = spawn_worker(**spawn_kwargs)
      handle.wait(timeout: timeout)
      handle
    end

    def run_report_and_wait(timeout: 60, **spawn_kwargs)
      handle = spawn_report(**spawn_kwargs)
      handle.wait(timeout: timeout)
      handle
    end

    def spawn(cli_args, chdir:, env: {})
      dir = Dir.mktmpdir("hopper-proc")
      command = [Gem.ruby, "-rbundler/setup", "-I", LIB, EXE, *cli_args]
      full_env = base_env.merge(env.transform_keys(&:to_s))
      pid = Process.spawn(
        full_env, *command,
        chdir: chdir, pgroup: true,
        in: File::NULL, out: [File.join(dir, "stdout"), "w"], err: [File.join(dir, "stderr"), "w"]
      )
      handle = ProcessHandle.new(pid: pid, command: command, dir: dir)
      live << handle
      handle
    end

    def base_env
      {
        "BUNDLE_GEMFILE" => GEMFILE,
        "RUBYOPT" => nil, # -rbundler/setup is passed explicitly
        "TEST_ENV_NUMBER" => nil,
        "SPEC_OPTS" => nil,
        "HOPPER_BUILD_ID" => nil, "HOPPER_WORKER_ID" => nil, "HOPPER_REDIS_URL" => nil, "REDIS_URL" => nil,
        "CIRCLECI" => nil, "BUILDKITE" => nil, "GITHUB_ACTIONS" => nil, "GITLAB_CI" => nil
      }
    end

    # Kills and removes every process and state dir spawned so far.
    def cleanup!
      live.each(&:close)
      live.clear
      state_dirs.each { |d| FileUtils.rm_rf(d) }
      state_dirs.clear
    end
  end
end

RSpec.configure do |config|
  config.after { HopperSpec::Fixtures.cleanup! }
  config.after(:suite) { HopperSpec::Fixtures.cleanup! }
end
