# frozen_string_literal: true

RSpec.describe RSpec::Hopper::Worker::BufferingReporter do
  subject(:buffer) { described_class.new }

  # A fixture group run inside the sandbox; not a spec of this suite.
  # rubocop:disable-next RSpec/NoExpectationExample, RSpec/ExpectActual, RSpec/IdenticalEqualityAssertion
  def fixture_group
    RSpec.describe("buffered") do
      it("passes") { expect(1).to eq(1) }
      it("fails") { raise "boom" }

      it("pending") do
        pending("later")
        raise "x"
      end
    end
  end

  it "records buffered notifications and replays them in order exactly once" do
    real = instance_double(RSpec::Core::Reporter)
    calls = []
    %i[example_group_started example_started example_failed example_finished example_group_finished message]
      .each { |name| allow(real).to receive(name) { |*args| calls << [name, args] } }

    buffer.example_group_started(:group)
    buffer.example_started(:ex)
    buffer.example_failed(:ex)
    buffer.example_finished(:ex)
    buffer.message("hello")
    buffer.example_group_finished(:group)
    expect(buffer.size).to eq(6)

    buffer.replay(real)
    expect(calls).to eq([[:example_group_started, [:group]], [:example_started, [:ex]], [:example_failed, [:ex]],
                         [:example_finished, [:ex]], [:message, ["hello"]], [:example_group_finished, [:group]]])
    expect(buffer).to be_empty
    buffer.replay(real)
    expect(calls.size).to eq(6)
  end

  it "discards without forwarding" do
    real = instance_double(RSpec::Core::Reporter)
    buffer.example_started(:ex)
    buffer.discard
    expect(buffer).to be_empty
    buffer.replay(real)
  end

  it "never fails fast and leaves suite lifecycle notifications to the outer runner" do
    expect(buffer.fail_fast_limit_met?).to be(false)
    %i[start finish close report exit_early abort_with].each do |name|
      expect(buffer).not_to respond_to(name)
    end
  end

  it "buffers everything a real group run sends and replays it to a real reporter" do
    RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      group = fixture_group
      group.run(buffer)
      names = buffer.events.map(&:first)
      expect(names).to include(:example_group_started, :example_started, :example_passed, :example_failed,
                               :example_pending, :example_finished, :example_group_finished)
      expect(names.first).to eq(:example_group_started)
      expect(names.last).to eq(:example_group_finished)

      spy = HopperSpec::RSpecSandbox::ReporterSpy.new.attach(config.reporter)
      buffer.replay(config.reporter)
      expect(spy.count(:example_passed)).to eq(1)
      expect(spy.count(:example_failed)).to eq(1)
      expect(spy.count(:example_pending)).to eq(1)
      expect(spy.count(:example_group_started)).to eq(1)
      expect(config.reporter.failed_examples.size).to eq(1)
    end
  end
end
