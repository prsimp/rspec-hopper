# frozen_string_literal: true

# Fixture: broken_spec.rb raises while being loaded; fine_spec.rb is healthy.

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
