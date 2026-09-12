# frozen_string_literal: true

# The shared-boot recipe from the rspec-hopper README, verbatim: close the
# boot-time connection before forking, and in each child re-read
# config/database.yml so its ERB sees the child's TEST_ENV_NUMBER.
require "rspec/hopper"

RSpec::Hopper.before_fork do
  ActiveRecord::Base.connection_handler.clear_all_connections!
end

RSpec::Hopper.after_fork do |_env_number|
  ActiveRecord::Base.configurations = Rails.application.config.database_configuration
  ActiveRecord::Base.establish_connection(Rails.env.to_sym)
end
