# frozen_string_literal: true

require "fileutils"

module HopperSpec
  # The Rails application under examples/rails-app, driven by real
  # `rspec-hopper` processes from its own bundle. Examples tagged `:rails`
  # are skipped unless that bundle is installed.
  module RailsExample
    DIR = File.join(Fixtures::ROOT, "examples", "rails-app")
    GEMFILE = File.join(DIR, "Gemfile")
    EXAMPLE_COUNT = 12

    module_function

    def dir = DIR

    def available?
      return @available unless @available.nil?

      @available = File.exist?(File.join(DIR, "Gemfile.lock")) && bundle_check
    end

    def bundle_check
      Bundler.with_unbundled_env do
        system("bundle", "check", chdir: DIR, out: File::NULL, err: File::NULL)
      end
    end

    def unavailable_message
      "examples/rails-app bundle not installed (run `bundle install` in examples/rails-app)"
    end

    # Spawns `rspec-hopper work` inside the app, on the app's bundle. The
    # suite itself runs under `bundle exec`, which exports the root project's
    # lockfile path along with BUNDLE_GEMFILE; overriding only the Gemfile
    # would make the child resolve the app's Gemfile against the gem's lock.
    def spawn_work(build_id:, worker_id:, redis_url:, args: [])
      Bundler.with_unbundled_env do
        Fixtures.spawn(["work", "--build", build_id, "--worker", worker_id, "--redis", redis_url, *args],
                       chdir: DIR, env: { "BUNDLE_GEMFILE" => GEMFILE })
      end
    end

    # Per-process SQLite files, the flaky counter and logs of the last run.
    def clean!
      FileUtils.rm_f(Dir[File.join(DIR, "db", "*.sqlite3*")])
      FileUtils.rm_rf(File.join(DIR, "tmp"))
      FileUtils.rm_rf(File.join(DIR, "log"))
    end

    def databases = Dir[File.join(DIR, "db", "*.sqlite3")].map { |path| File.basename(path) }.sort
  end
end

RSpec.configure do |config|
  config.before(:each, :rails) do
    skip HopperSpec::RailsExample.unavailable_message unless HopperSpec::RailsExample.available?
  end
end
