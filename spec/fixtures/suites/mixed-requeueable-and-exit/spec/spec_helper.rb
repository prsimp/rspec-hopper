# frozen_string_literal: true

# Fixture: one file: the first example raises RuntimeError (requeueable), the second raises SystemExit (never requeueable), so the unit must be finalized as a test_failure on its first attempt.

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
