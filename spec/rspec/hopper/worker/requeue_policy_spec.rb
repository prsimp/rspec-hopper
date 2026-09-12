# frozen_string_literal: true

RSpec.describe RSpec::Hopper::Worker::RequeuePolicy do
  # Fixture examples whose results are set by hand; not specs of this suite.
  def examples_with(*statuses)
    RSpec::Core::Sandbox.sandboxed do
      group = RSpec.describe("policy") do
        statuses.each_index { |i| it("example #{i}") { nil } } # rubocop:disable RSpec/NoExpectationExample
      end
      examples = group.examples
      examples.zip(statuses).each do |example, (status, exception)|
        example.execution_result.status = status
        example.execution_result.exception = exception
      end
      yield examples
    end
  end

  it "reports passed when no example failed" do
    examples_with([:passed], [:pending], [:passed]) do |examples|
      decision = described_class.decide(examples)
      expect(decision).to be_passed
      expect(decision.failure_count).to eq(0)
      expect(decision.errors).to eq([])
    end
  end

  it "is a requeue candidate when every failure is requeueable" do
    examples_with([:failed, RuntimeError.new("a")], [:passed], [:failed, ArgumentError.new("b")]) do |examples|
      decision = described_class.decide(examples)
      expect(decision).to be_requeue_candidate
      expect(decision.summary).to eq("2 failures")
      expect(decision.errors.map { |e| e["class"] }).to eq(%w[RuntimeError ArgumentError])
      expect(decision.errors.first).to include("example_id" => examples.first.id, "message" => "a")
      expect(decision.errors.first["description"]).to include("policy example 0")
    end
  end

  it "is final when a SystemExit escaped an example alongside a RuntimeError" do
    examples_with([:failed, RuntimeError.new("a")], [nil], [nil]) do |examples|
      examples[1].execution_result.started_at = Time.now
      decision = described_class.decide(examples, escaped: SystemExit.new(1, "exit"))
      expect(decision).to be_final_failure
      expect(decision.unexecuted).to eq(examples[1..])
      expect(decision.failure_count).to eq(2)
      expect(decision.errors.last).to include("class" => "SystemExit", "example_id" => examples[1].id)
    end
  end

  it "is final when an aggregate error contains a non-requeueable exception" do
    multiple = RSpec::Core::MultipleExceptionError.new(RuntimeError.new("a"), Interrupt.new)
    examples_with([:failed, multiple]) do |examples|
      expect(described_class.decide(examples)).to be_final_failure
      expect(described_class.exceptions_of(examples.first).map(&:class)).to eq([RuntimeError, Interrupt])
    end
  end

  it "flattens aggregate errors made only of requeueable exceptions" do
    multiple = RSpec::Core::MultipleExceptionError.new(RuntimeError.new("a"), RuntimeError.new("b"))
    examples_with([:failed, multiple]) do |examples|
      decision = described_class.decide(examples)
      expect(decision).to be_requeue_candidate
      expect(decision.errors.size).to eq(2)
      expect(decision.summary).to eq("1 failure")
    end
  end

  it "treats SystemExit, Interrupt, SignalException and NoMemoryError as non-requeueable" do
    [SystemExit.new, Interrupt.new, SignalException.new("TERM"), NoMemoryError.new].each do |error|
      expect(described_class.requeueable?(error)).to be(false)
    end
    expect(described_class.requeueable?(StandardError.new)).to be(true)
    expect(described_class.requeueable?(RSpec::Expectations::ExpectationNotMetError.new)).to be(true)
  end

  it "pluralizes the failure summary" do
    expect(described_class.failure_summary(1)).to eq("1 failure")
    expect(described_class.failure_summary(0)).to eq("0 failures")
    expect(described_class.failure_summary(3)).to eq("3 failures")
  end
end
