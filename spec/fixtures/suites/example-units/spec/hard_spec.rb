# frozen_string_literal: true

RSpec.describe "hard failure" do
  it "fails every time" do
    raise "hard failure on purpose"
  end

  it "passes" do
    expect(true).to be(true)
  end
end
