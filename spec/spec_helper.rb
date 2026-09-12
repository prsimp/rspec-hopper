# frozen_string_literal: true

require "rspec/hopper"
require "securerandom"
require "stringio"
require "tmpdir"
require "timeout"

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
