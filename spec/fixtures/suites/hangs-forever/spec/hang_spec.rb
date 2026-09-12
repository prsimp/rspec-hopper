# frozen_string_literal: true

RSpec.describe "hang" do
  it "never finishes" do
    sleep
  end
end
