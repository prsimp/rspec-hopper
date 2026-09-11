# frozen_string_literal: true

# Fixture: a before(:all) hook sets an ivar the examples assert on; fails visibly if context hooks do not fire.

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
