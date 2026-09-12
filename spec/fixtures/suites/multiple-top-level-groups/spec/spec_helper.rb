# frozen_string_literal: true

# Fixture: a single file declaring three top-level example groups (1, 2 and 2 examples).

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
