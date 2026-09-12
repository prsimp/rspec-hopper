# frozen_string_literal: true

# Fixture: one file passes; one file has a single deterministic failure.

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
