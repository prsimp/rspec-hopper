# frozen_string_literal: true

# Fixture: support/env_capture.rb records TEST_ENV_NUMBER at load time; each example compares it with the run-time value and appends both to HOPPER_FIXTURE_STATE_DIR/env-<pid>.

require "tmpdir"

# Cross-process state shared by every attempt of this fixture. Integration
# specs point HOPPER_FIXTURE_STATE_DIR at a fresh directory per run; without
# it the system tmpdir is used and counters may carry over between runs.
module FixtureState
  DIR = ENV.fetch("HOPPER_FIXTURE_STATE_DIR") { Dir.tmpdir }

  def self.path(name) = File.join(DIR, name)

  # Atomically increments a counter file and returns the new value.
  def self.increment(name)
    File.open(path(name), File::RDWR | File::CREAT, 0o644) do |f|
      f.flock(File::LOCK_EX)
      count = f.read.to_i + 1
      f.rewind
      f.truncate(0)
      f.write(count.to_s)
      f.flush
      count
    end
  end
end

require "support/env_capture"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
