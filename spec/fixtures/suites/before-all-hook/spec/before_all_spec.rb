# frozen_string_literal: true

RSpec.describe "before(:all)" do
  before(:all) do
    @shared = 42
  end

  it "sees the value set by the context hook" do
    expect(@shared).to eq(42)
  end

  it "sees it in every example" do
    expect(@shared).to eq(42)
  end

  context "nested" do
    it "inherits the context ivar" do
      expect(@shared).to eq(42)
    end
  end
end
