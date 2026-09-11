# frozen_string_literal: true

# Confirms the worker coexists with a gem that prepends onto
# RSpec::Core::Example#run and #finish. datadog-ci is configured in agentless
# mode with a dummy API key and every network-facing feature disabled, so no
# request is ever attempted: traces go to its NullTransport, telemetry is off,
# and no test session (which is what triggers remote settings fetches) starts.
begin
  ENV["DD_INSTRUMENTATION_TELEMETRY_ENABLED"] = "false"
  require "socket"
  require "datadog/ci"
  HOPPER_DATADOG_AVAILABLE = true
rescue LoadError => e
  HOPPER_DATADOG_LOAD_ERROR = e
  HOPPER_DATADOG_AVAILABLE = false
end

module HopperSpec
  module DatadogSetup
    # Dummy git metadata: the temporary project is not a git checkout, and
    # datadog logs an error per example when it cannot extract these.
    GIT_ENV = { "DD_GIT_REPOSITORY_URL" => "https://example.invalid/rspec-hopper.git",
                "DD_GIT_COMMIT_SHA" => "0" * 40 }.freeze

    module_function

    def configure_once!
      return if @configured

      GIT_ENV.each { |key, value| ENV[key] ||= value }
      Datadog.configure do |c|
        configure_core(c)
        configure_ci(c)
        c.ci.instrument :rspec
      end
      @configured = true
    end

    def configure_core(settings)
      settings.tracing.enabled = true
      settings.telemetry.enabled = false
      settings.remote.enabled = false
      settings.crashtracking.enabled = false if settings.respond_to?(:crashtracking)
      settings.diagnostics.startup_logs.enabled = false
      settings.api_key = "hopper-contract-spec"
    end

    def configure_ci(settings)
      settings.ci.enabled = true
      settings.ci.agentless_mode_enabled = true
      settings.ci.discard_traces = true
      settings.ci.force_test_level_visibility = true
      settings.ci.git_metadata_upload_enabled = false
      settings.ci.itr_enabled = false
      settings.ci.retry_failed_tests_enabled = false
      settings.ci.retry_new_tests_enabled = false
      settings.ci.test_management_enabled = false
      settings.ci.impacted_tests_detection_enabled = false
      settings.ci.agentless_logs_submission_enabled = false
    end

    def enabled=(value)
      Datadog.configuration.ci.enabled = value
      Datadog.configuration.ci[:rspec].enabled = value
    end
  end
end

RSpec.describe "Example prepend coexistence with datadog-ci" do
  before do
    skip "datadog-ci could not be loaded: #{HOPPER_DATADOG_LOAD_ERROR}" unless HOPPER_DATADOG_AVAILABLE
    HopperSpec::DatadogSetup.configure_once!
    HopperSpec::DatadogSetup.enabled = true
  end

  after { HopperSpec::DatadogSetup.enabled = false if HOPPER_DATADOG_AVAILABLE }

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:config) { work_config(max_requeues: 2, requeue_tolerance: 1.0) }
  let(:queue) { HopperSpec::FakeQueue.new(max_requeues: 2, requeue_tolerance: 1.0) }
  let(:files) do
    { "spec/flaky_spec.rb" => HopperSpec::RSpecSandbox.flaky_spec,
      "spec/a_spec.rb" => HopperSpec::RSpecSandbox::PASSING_SPEC }
  end

  it "has datadog's instrumentation prepended onto Example and the worker still retries and reports once" do
    expect(RSpec::Core::Example.ancestors).to include(Datadog::CI::Contrib::RSpec::Example::InstanceMethods)
    expect(RSpec::Core::Example.ancestors.index(Datadog::CI::Contrib::RSpec::Example::InstanceMethods))
      .to be < RSpec::Core::Example.ancestors.index(RSpec::Core::Example)

    allow(TCPSocket).to receive(:open).and_raise("network I/O attempted by datadog")
    allow(TCPSocket).to receive(:new).and_raise("network I/O attempted by datadog")

    traced = []
    tracing = Datadog.send(:components).test_tracing
    allow(tracing).to receive(:trace_test).and_wrap_original do |original, *args, **kwargs, &block|
      traced << args.first
      original.call(*args, **kwargs, &block)
    end

    code = nil
    spy = nil
    with_project(files) do
      suite = load_suite([], config: config, out: out, err: err)
      spy = HopperSpec::RSpecSandbox::ReporterSpy.new.attach(suite.configuration.reporter)
      code = RSpec::Hopper::Worker.new(config: config, queue_factory: -> { queue }, suite: suite, out: out,
                                       err: err).run
    end

    expect(code).to eq(0)
    expect(queue.events_of("requeued").map { |e| e["unit_id"] }).to eq(["./spec/flaky_spec.rb"])
    expect(queue.events_of("finalized").map { |e| [e["unit_id"], e["outcome"]] })
      .to contain_exactly(["./spec/a_spec.rb", "passed"], ["./spec/flaky_spec.rb", "passed"])
    expect(spy.times_seen("./spec/flaky_spec.rb[1:1]")).to eq(1)
    expect(spy.count(:example_started)).to eq(4)
    expect(spy.count(:example_failed)).to eq(0)
    expect(out.string).to include("Retrying ./spec/flaky_spec.rb (retry 1 of 2; next attempt 2): 1 failure")
      .and include("4 examples, 0 failures")

    expect(traced.size).to eq(6)
    expect(traced.count { |name| name.include?("passes on the second attempt") }).to eq(2)
  end
end
