# frozen_string_literal: true

RSpec.describe RSpec::Hopper do
  it "has a version number" do
    expect(RSpec::Hopper::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  describe ".before_fork / .after_fork" do
    it "registers hooks in order" do
      a = described_class.before_fork { :a }
      b = described_class.after_fork { |_n| :b }
      expect(described_class.before_fork_hooks).to eq([a])
      expect(described_class.after_fork_hooks).to eq([b])
    end
  end
end
