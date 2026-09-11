# frozen_string_literal: true

RSpec.describe "aborts the process" do
  it "kills itself with SIGKILL" do
    Process.kill("KILL", Process.pid)
    sleep 5
  end
end
