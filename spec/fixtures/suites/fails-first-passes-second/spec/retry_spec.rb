# frozen_string_literal: true

RSpec.describe "fails first, passes second" do
  it "always passes" do
    expect(true).to be(true)
  end

  it "fails on the first attempt only" do
    attempt = FixtureState.increment("fails-first-attempts")
    expect(attempt).to be >= 2, "attempt #{attempt} fails on purpose"
  end
end
