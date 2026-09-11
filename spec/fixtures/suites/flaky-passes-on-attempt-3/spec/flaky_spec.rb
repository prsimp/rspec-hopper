# frozen_string_literal: true

RSpec.describe "flaky" do
  it "passes only from the third attempt" do
    attempt = FixtureState.increment("flaky-attempts")
    expect(attempt).to be >= 3, "attempt #{attempt} fails on purpose"
  end

  it "always passes in the same file" do
    expect(true).to be(true)
  end
end
