# frozen_string_literal: true

# Fixture: hang_spec.rb sleeps forever; ok_spec.rb passes.

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
