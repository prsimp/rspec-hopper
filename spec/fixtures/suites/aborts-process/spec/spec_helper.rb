# frozen_string_literal: true

# Fixture: abort_spec.rb SIGKILLs its own process mid-example; ok_spec.rb passes.

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
