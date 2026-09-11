# frozen_string_literal: true

RSpec.describe "mixed" do
  it "is fast", :fast do
    expect(1).to eq(1)
  end

  it "is slow", :slow do
    expect(2).to eq(2)
  end
end
