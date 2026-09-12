# frozen_string_literal: true

# Fixture: like test-env-number, but registers RSpec::Hopper.after_fork to re-derive the value from the child's TEST_ENV_NUMBER; examples compare the derived value with the run-time one and append load/derived/run to HOPPER_FIXTURE_STATE_DIR/env-<pid>.

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

require "rspec/hopper"
require "support/env_capture"

RSpec::Hopper.before_fork { EnvCapture.before_fork_ran = true }
RSpec::Hopper.after_fork { |n| EnvCapture.derived = n }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
