# frozen_string_literal: true

RSpec.describe "flaky" do
  it "passes only from the third attempt" do
    attempt = FixtureState.increment("flaky-attempts")
    # Retried attempts can be slowed down (HOPPER_FIXTURE_RETRY_SLEEP seconds)
    # so a chaos spec has a window in which to kill the worker mid-retry.
    sleep ENV.fetch("HOPPER_FIXTURE_RETRY_SLEEP", "0").to_f if attempt >= 2
    expect(attempt).to be >= 3, "attempt #{attempt} fails on purpose"
  end

  it "always passes in the same file" do
    expect(true).to be(true)
  end
end
