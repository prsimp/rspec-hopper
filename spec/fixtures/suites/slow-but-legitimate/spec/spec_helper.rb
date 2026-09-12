# frozen_string_literal: true

# Fixture: slow_spec.rb sleeps HOPPER_FIXTURE_SLEEP seconds (default 8) then passes; ok_spec.rb passes.

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
