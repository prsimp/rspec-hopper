# frozen_string_literal: true

# Fixture: examples tagged :fast or :slow across fast_spec.rb, slow_spec.rb and mixed_spec.rb; .rspec is neutral, workers pass --tag fast (selects 3 examples in 2 files).

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
