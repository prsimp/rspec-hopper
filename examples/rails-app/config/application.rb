# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module RailsApp
  # The smallest Rails application that has a database and a request path:
  # enough to prove rspec-hopper's shared boot, per-child databases and
  # transactional tests against real ActiveRecord.
  class Application < Rails::Application
    config.load_defaults 8.0
    config.eager_load = false
    config.secret_key_base = "rspec-hopper-example-not-a-secret"
    config.logger = ActiveSupport::Logger.new(IO::NULL)
    config.active_record.dump_schema_after_migration = false
    config.active_support.deprecation = :stderr
  end
end
