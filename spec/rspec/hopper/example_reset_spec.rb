# frozen_string_literal: true

RSpec.describe RSpec::Hopper::ExampleReset do
  # Fixture groups run inside the sandbox; they are not specs of this suite.
  # rubocop:disable RSpec/NoExpectationExample, RSpec/ExpectActual, RSpec/IdenticalEqualityAssertion
  def sandboxed_group
    RSpec::Core::Sandbox.sandboxed do |_config|
      group = RSpec.describe("outer") do
        it("fails") { raise "nope" }
        it("passes") { expect(1).to eq(1) }

        describe "nested" do
          it("also fails") { raise "nested nope" }
        end
      end
      group.run(RSpec::Core::NullReporter)
      yield group
    end
  end

  def fresh_group = RSpec.describe("fresh") { it("x") { nil } }
  # rubocop:enable RSpec/NoExpectationExample, RSpec/ExpectActual, RSpec/IdenticalEqualityAssertion

  it "clears the exception and execution result of every selected example in the tree" do
    sandboxed_group do |group|
      examples = group.descendants.flat_map(&:filtered_examples)
      expect(examples.map { |e| e.execution_result.status }).to eq(%i[failed passed failed])
      count = described_class.reset([group])
      expect(count).to eq(3)
      examples.each do |example|
        expect(example.instance_variable_get(:@exception)).to be_nil
        expect(example.execution_result.status).to be_nil
        expect(example.execution_result).to be_a(RSpec::Core::Example::ExecutionResult)
      end
    end
  end

  it "is idempotent on examples that never ran" do
    RSpec::Core::Sandbox.sandboxed do
      group = fresh_group
      expect(described_class.reset(group)).to eq(1)
      expect(group.examples.first.execution_result.status).to be_nil
    end
  end

  it "pins the instance variables it relies on" do
    expect(described_class::EXPECTED_IVARS).to include(:@exception, :@metadata)
  end
end
