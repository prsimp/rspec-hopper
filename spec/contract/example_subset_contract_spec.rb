# frozen_string_literal: true

require "open3"
require "rbconfig"

# Guards the second sanctioned touch of rspec-core internals: the world's
# per-group example selection and the `descendant_filtered_examples` memo that
# ExampleSubset swaps around one `ExampleGroup.run` so an example unit runs one
# example with its file's context hooks. See lib/rspec/hopper/example_subset.rb.
RSpec.describe "ExampleSubset contract" do
  # A fixture group with context hooks at two levels and a sibling context
  # that must stay untouched; run inside the sandbox, not a spec of this suite.
  # rubocop:disable-next RSpec/NoExpectationExample, RSpec/LeakyLocalVariable, RSpec/BeforeAfterAll, RSpec/ContextWording
  def with_group
    RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      log = []
      group = RSpec.describe("contract") do
        before(:context) { log << :outer_before }
        after(:context) { log << :outer_after }

        it("one") { log << :one }
        it("two") { log << :two }

        context "inner" do
          before(:context) { log << :inner_before }
          after(:context) { log << :inner_after }

          it("three") { log << :three }
        end

        context "other" do
          before(:context) { log << :other_before }

          it("four") { log << :four }
        end
      end
      yield group, log
    end
  end

  def example_named(group, description)
    group.descendants.flat_map(&:examples).find { |ex| ex.description == description }
  end

  it "runs only the selected example, with the context hooks on its path and no others" do
    with_group do |group, log|
      three = example_named(group, "three")
      RSpec::Hopper::ExampleSubset.scoped(group, [three]) { group.run(RSpec::Core::NullReporter) }
      expect(log).to eq(%i[outer_before inner_before three inner_after outer_after])
      expect(three.execution_result.status).to eq(:passed)
      expect(example_named(group, "four").execution_result.status).to be_nil
    end
  end

  it "runs a top-level example without entering any nested context" do
    with_group do |group, log|
      two = example_named(group, "two")
      RSpec::Hopper::ExampleSubset.scoped(group, [two]) { group.run(RSpec::Core::NullReporter) }
      expect(log).to eq(%i[outer_before two outer_after])
    end
  end

  it "restores the world's selection and every group's memo afterwards, also when the block raises" do
    with_group do |group, _log|
      all = group.descendant_filtered_examples
      expect(all.size).to eq(4)
      inner = group.children.first
      inner_all = inner.descendant_filtered_examples
      three = example_named(group, "three")

      inside = nil
      expect do
        RSpec::Hopper::ExampleSubset.scoped(group, [three]) do
          inside = [group.filtered_examples, group.descendant_filtered_examples, inner.descendant_filtered_examples,
                    group.children.last.descendant_filtered_examples]
          raise "boom"
        end
      end.to raise_error("boom")
      expect(inside).to eq([[], [three], [three], []])

      expect(group.filtered_examples).to eq(all.first(2))
      expect(group.descendant_filtered_examples).to equal(all)
      expect(inner.descendant_filtered_examples).to equal(inner_all)
      expect(RSpec.world.filtered_examples[group.children.last]).to eq([example_named(group, "four")])
    end
  end

  it "reads the selection through the world hash that ExampleGroup.run consults" do
    with_group do |group, _log|
      expect(RSpec.world.filtered_examples).to be_a(Hash)
      expect(group.filtered_examples).to equal(RSpec.world.filtered_examples[group])
    end
  end

  it "pins the class instance variables of a run example group under bare rspec-core" do
    script = <<~RUBY
      require "rspec/core"
      group = RSpec.describe("bare") { it("x") {}; context("c") { it("y") {} } }
      group.run(RSpec::Core::NullReporter)
      print group.instance_variables.sort.inspect
    RUBY
    output, status = Open3.capture2(RbConfig.ruby, "-e", script)
    expect(status).to be_success
    expect(output).to eq(RSpec::Hopper::ExampleSubset::EXPECTED_GROUP_IVARS.sort.inspect)
    expect(RSpec::Hopper::ExampleSubset::EXPECTED_GROUP_IVARS).to include(RSpec::Hopper::ExampleSubset::MEMO_IVAR)
  end
end
