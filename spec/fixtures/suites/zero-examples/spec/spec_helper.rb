# frozen_string_literal: true

# Fixture: two files whose examples all carry :skip_me, and .rspec excludes that tag, so zero examples are selected.

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
