# frozen_string_literal: true

require "json"

module EnvCapture
  UNSET = "<unset>"
  LOADED = ENV.fetch("TEST_ENV_NUMBER", UNSET)

  def self.current = ENV.fetch("TEST_ENV_NUMBER", UNSET)

  # Appends one JSON line per example to env-<pid> in the state dir.
  def self.record(file, **values)
    line = { "pid" => Process.pid, "file" => File.basename(file) }.merge(values)
    File.open(FixtureState.path("env-#{Process.pid}"), "a") { |f| f.puts JSON.generate(line) }
  end
end
