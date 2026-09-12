# frozen_string_literal: true

RSpec.describe "flaky file" do
  before(:all) do
    FixtureState.increment("before-all-runs")
    @shared = 42
  end

  it "passes from the second attempt" do
    attempt = FixtureState.increment("flaky-attempts")
    expect(attempt).to be >= 2, "attempt #{attempt} fails on purpose"
  end

  it "always passes and sees the context ivar" do
    expect(@shared).to eq(42)
  end

  context "nested" do
    it "also sees the context ivar" do
      expect(@shared).to eq(42)
    end
  end
end
