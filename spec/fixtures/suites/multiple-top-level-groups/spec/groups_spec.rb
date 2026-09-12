# frozen_string_literal: true

RSpec.describe "first group" do
  it "passes" do
    expect(1).to eq(1)
  end
end

RSpec.describe "second group" do
  it "passes" do
    expect(2).to eq(2)
  end

  it "passes again" do
    expect(2).to be_even
  end
end

RSpec.describe "third group" do
  it "passes" do
    expect(3).to eq(3)
  end

  it "passes again" do
    expect(3).to be_odd
  end
end
