# frozen_string_literal: true

# Fixture: .rspec contains --fail-fast, which hopper must reject with exit 2; the one spec passes.

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
