# frozen_string_literal: true

require "rspec/hopper"
require "securerandom"
require "stringio"
require "tmpdir"
require "timeout"

# CI captures a pipe, and Ruby block-buffers a non-TTY stdout: without this the
# progress formatter's output arrives in one lump when the suite ends, which
# reads as a hung job and gives a no-output timeout nothing to see.
$stdout.sync = true

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.filter_run_when_matching :focus

  config.before(:each, :redis) do
    skip HopperSpec::RedisHelper.unavailable_message unless HopperSpec::RedisHelper.available?
  end

  config.after { RSpec::Hopper.reset_hooks! }
end
