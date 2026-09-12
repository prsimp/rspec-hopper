# frozen_string_literal: true

raise "broken_spec.rb raises at load time"

RSpec.describe "never defined" do
  it "is unreachable" do
    expect(true).to be(true)
  end
end
