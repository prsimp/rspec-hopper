# frozen_string_literal: true

RSpec.describe "flaky a" do
  it "fails on its first attempt only" do
    attempt = FixtureState.increment("attempts-#{File.basename(__FILE__)}")
    expect(attempt).to be >= 2, "attempt #{attempt} of flaky a fails on purpose"
  end
end
