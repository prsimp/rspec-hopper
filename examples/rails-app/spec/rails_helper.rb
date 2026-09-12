# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"

Dir[Rails.root.join("spec/support/**/*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  # Runs in every worker process, after the after_fork hooks under shared
  # boot, so each process checks and prepares the database it will use.
  config.before(:suite) do
    DatabaseGuard.check!
    DatabaseGuard.load_schema!
  end
end
