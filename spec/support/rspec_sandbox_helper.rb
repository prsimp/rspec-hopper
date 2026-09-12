# frozen_string_literal: true

require "fileutils"
require "rspec/core/sandbox"
require "stringio"
require "tmpdir"

module HopperSpec
  # Lets fixture spec files call back into the outer example (for instance to
  # reclaim the unit or vanish build state while it runs).
  module FixtureHooks
    @hooks = {}

    class << self
      def on(name, &block) = @hooks[name] = block
      def fire(name) = @hooks[name]&.call
      def reset! = @hooks = {}
    end
  end

  # Runs a real rspec-core world in-process, isolated by RSpec::Core::Sandbox,
  # against a temporary project directory holding fixture spec files.
  #
  # RSpec memoizes the project directory (`Metadata.relative_path_regex`) the
  # first time it relativizes a path, so `./spec/...` ids for a temporary
  # project require clearing that memo around the sandbox. That is the only
  # RSpec internal these helpers touch, and only in test support.
  module RSpecSandbox
    PASSING_SPEC = <<~RUBY
      RSpec.describe "passing" do
        it("one") { expect(1).to eq(1) }
        it("two") { expect(2).to eq(2) }
      end
    RUBY

    FAILING_SPEC = <<~RUBY
      RSpec.describe "failing" do
        it("boom") { raise "boom" }
        it("fine") { expect(true).to be(true) }
      end
    RUBY

    # Fails the first time it runs in a process and passes afterwards.
    def self.flaky_spec(marker = "flaky.marker")
      <<~RUBY
        RSpec.describe "flaky" do
          it "passes on the second attempt" do
            marker = File.expand_path(#{marker.inspect})
            if File.exist?(marker)
              expect(File.read(marker)).to eq(Process.pid.to_s)
            else
              File.write(marker, Process.pid.to_s)
              raise "first attempt fails"
            end
          end
          it("steady") { expect(:ok).to eq(:ok) }
        end
      RUBY
    end

    # Writes `files` (relative path => content) into a fresh temporary project,
    # chdirs into it, isolates HOME/SPEC_OPTS, and yields inside a sandbox.
    def with_project(files, dot_rspec: nil)
      Dir.mktmpdir("hopper-suite") do |dir|
        files.each do |path, content|
          full = File.join(dir, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
        File.write(File.join(dir, ".rspec"), dot_rspec) if dot_rspec
        in_project_dir(dir) { |config| yield dir, config }
      end
    end

    def in_project_dir(dir, &block)
      saved = ENV.to_h.slice("HOME", "XDG_CONFIG_HOME", "SPEC_OPTS")
      ENV["HOME"] = dir
      ENV["XDG_CONFIG_HOME"] = File.join(dir, ".config")
      ENV.delete("SPEC_OPTS")
      Dir.chdir(dir) do
        with_relative_path_memo_cleared { RSpec::Core::Sandbox.sandboxed(&block) }
      end
    ensure
      %w[HOME XDG_CONFIG_HOME SPEC_OPTS].each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
    end

    def with_relative_path_memo_cleared
      RSpec::Core::Metadata.instance_variable_set(:@relative_path_regex, nil)
      yield
    ensure
      RSpec::Core::Metadata.instance_variable_set(:@relative_path_regex, nil)
    end

    def work_config(**attrs)
      RSpec::Hopper::WorkConfig.build(build_id: "build-1", worker_id: "w1", redis_url: "redis://unused", **attrs)
    end

    def load_suite(args = [], config: work_config, out: StringIO.new, err: StringIO.new)
      RSpec::Hopper::Worker::Suite.load(args, config: config, out: out, err: err)
    end

    # What `Worker#run` produced, captured while the sandbox was still active
    # (Suite#configuration reads the global RSpec configuration afterwards).
    WorkerRun = Struct.new(:code, :suite, :spy, :configuration, keyword_init: true)

    # Counts notifications reaching the real reporter.
    class ReporterSpy
      NOTIFICATIONS = %i[
        start example_group_started example_started example_passed example_failed example_pending
        example_finished dump_summary close
      ].freeze

      attr_reader :calls

      def initialize
        @calls = Hash.new(0)
        @examples = Hash.new(0)
      end

      NOTIFICATIONS.each do |name|
        define_method(name) do |notification|
          @calls[name] += 1
          @examples[[name, notification.example.id]] += 1 if notification.respond_to?(:example)
        end
      end

      def count(name) = @calls[name]
      # How many times the example reached the reporter through `notification`.
      def times_seen(example_id, notification = :example_started) = @examples[[notification, example_id]]

      def attach(reporter)
        reporter.register_listener(self, *NOTIFICATIONS)
        self
      end
    end
  end
end

RSpec.configure do |config|
  config.include HopperSpec::RSpecSandbox
  config.after { HopperSpec::FixtureHooks.reset! }
end
