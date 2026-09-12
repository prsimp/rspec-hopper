# frozen_string_literal: true

RSpec.describe "flaky b" do
  it "fails on its first attempt only" do
    attempt = FixtureState.increment("attempts-#{File.basename(__FILE__)}")
    expect(attempt).to be >= 2, "attempt #{attempt} of flaky b fails on purpose"
  end
end
