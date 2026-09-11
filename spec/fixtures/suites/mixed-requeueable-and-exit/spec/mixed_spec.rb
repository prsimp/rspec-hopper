# frozen_string_literal: true

RSpec.describe "mixed requeueable and exit" do
  it "raises a requeueable RuntimeError" do
    raise "requeueable failure"
  end

  it "raises SystemExit, which is never requeueable" do
    raise SystemExit.new(1, "exit requested from an example")
  end
end
