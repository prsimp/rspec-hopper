# frozen_string_literal: true

RSpec.describe "slow", :slow do
  it "is slow" do
    expect(1).to eq(1)
  end

  it "is slow too" do
    expect(2).to eq(2)
  end
end
