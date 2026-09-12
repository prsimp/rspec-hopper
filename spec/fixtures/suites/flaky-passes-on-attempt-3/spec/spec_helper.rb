# frozen_string_literal: true

# Fixture: flaky_spec.rb fails on attempts 1 and 2 and passes from attempt 3, counting attempts in HOPPER_FIXTURE_STATE_DIR so retries by different processes share the count (retried attempts sleep HOPPER_FIXTURE_RETRY_SLEEP seconds, default 0); stable_spec.rb always passes.

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

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
