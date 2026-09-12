# frozen_string_literal: true

require "open3"
require "rbconfig"

# Guards the one sanctioned touch of RSpec::Core::Example internals. See the
# product spec, "Retry state isolation".
RSpec.describe "ExampleReset contract" do
  # A fixture example whose body fails only the first time it executes; it is
  # run inside the sandbox and is not a spec of this suite.
  # rubocop:disable-next RSpec/NoExpectationExample, RSpec/LeakyLocalVariable
  def with_flaky_example
    RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      attempts = []
      group = RSpec.describe("contract") do
        it("passes on the second execution") do
          attempts << :run
          raise "first execution fails" if attempts.size == 1
        end
      end
      yield group, group.examples.first, attempts
    end
  end

  it "reports a failure again without the reset, even though the body passed" do
    with_flaky_example do |group, example, attempts|
      group.run(RSpec::Core::NullReporter)
      expect(example.execution_result.status).to eq(:failed)

      group.run(RSpec::Core::NullReporter)
      expect(attempts.size).to eq(2)
      expect(example.execution_result.status).to eq(:failed)
      expect(example.exception.message).to eq("first execution fails")
    end
  end

  it "reports a clean pass on the second execution with the reset" do
    with_flaky_example do |group, example, attempts|
      group.run(RSpec::Core::NullReporter)
      expect(example.execution_result.status).to eq(:failed)

      RSpec::Hopper::ExampleReset.reset([group])
      buffer = RSpec::Hopper::Worker::BufferingReporter.new
      group.run(buffer)
      expect(attempts.size).to eq(2)
      expect(example.execution_result.status).to eq(:passed)
      expect(example.exception).to be_nil
      expect(buffer.events.map(&:first)).to include(:example_passed)
      expect(buffer.events.map(&:first)).not_to include(:example_failed)
    end
  end

  it "pins the instance variable list of a run example under bare rspec-core" do
    script = <<~RUBY
      require "rspec/core"
      group = RSpec.describe("bare") { it("x") { raise "nope" } }
      group.run(RSpec::Core::NullReporter)
      print group.examples.first.instance_variables.sort.inspect
    RUBY
    output, status = Open3.capture2(RbConfig.ruby, "-e", script)
    expect(status).to be_success
    expect(output).to eq(RSpec::Hopper::ExampleReset::EXPECTED_IVARS.sort.inspect)
  end

  it "finds nothing beyond the pinned list in this process that the reset would need to touch" do
    with_flaky_example do |group, example, _attempts|
      group.run(RSpec::Core::NullReporter)
      expect(RSpec::Hopper::ExampleReset::EXPECTED_IVARS - example.instance_variables).to be_empty
    end
  end
end
