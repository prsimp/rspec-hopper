# frozen_string_literal: true

RSpec.describe "slow but legitimate" do
  it "takes a while and passes" do
    sleep ENV.fetch("HOPPER_FIXTURE_SLEEP", "8").to_f
    expect(true).to be(true)
  end
end
