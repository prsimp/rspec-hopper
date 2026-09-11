# frozen_string_literal: true

# rubocop:disable-next Style/FormatStringToken -- "%{n}" is the documented placeholder syntax
RSpec.describe RSpec::Hopper::CLI::FormatterArgs do
  describe ".split" do
    it "returns the arguments unchanged when there are no formatter options" do
      expect(described_class.split(%w[--tag fast spec/a])).to eq([%w[--tag fast spec/a], []])
    end

    it "strips every spelling of --format and --out, normalized to long pairs, in order" do
      args = %w[--tag fast --format json --out out.json -f doc -fhtml --format=progress
                -o o1 -oo2 --out=o3 spec/a]
      remaining, pairs = described_class.split(args)
      expect(remaining).to eq(%w[--tag fast spec/a])
      expect(pairs).to eq([
                            %w[--format json], %w[--out out.json], %w[--format doc], %w[--format html],
                            %w[--format progress], %w[--out o1], %w[--out o2], %w[--out o3]
                          ])
    end

    it "leaves everything after -- untouched" do
      args = %w[--format json -- --format spec/--out -o]
      expect(described_class.split(args)).to eq([%w[-- --format spec/--out -o], [%w[--format json]]])
    end

    it "leaves a dangling flag with no value for RSpec to report" do
      expect(described_class.split(%w[--tag x --format])).to eq([%w[--tag x --format], []])
    end

    it "does not confuse other options that share a prefix" do
      args = %w[--formatter-ish x --order rand -fail]
      remaining, pairs = described_class.split(args)
      expect(remaining).to eq(%w[--formatter-ish x --order rand])
      expect(pairs).to eq([%w[--format ail]])
    end

    it "does not mutate its input" do
      args = %w[--format json spec]
      described_class.split(args)
      expect(args).to eq(%w[--format json spec])
    end
  end

  describe ".for_child" do
    let(:pairs) { [%w[--format json], ["--out", "tmp/%{n}/report-%{n}.json"], %w[--format doc]] }

    it "substitutes %{n} in --out paths with the child's TEST_ENV_NUMBER" do
      expect(described_class.for_child(pairs, "2"))
        .to eq(%w[--format json --out tmp/2/report-2.json --format doc])
    end

    it "substitutes the empty string for the first child" do
      expect(described_class.for_child(pairs, "")).to eq(%w[--format json --out tmp//report-.json --format doc])
    end

    it "leaves --format values and paths without a placeholder alone" do
      expect(described_class.for_child([["--format", "%{n}"], %w[--out plain.xml]], "3"))
        .to eq(["--format", "%{n}", "--out", "plain.xml"])
    end

    it "treats the placeholder literally even next to other percent signs" do
      expect(described_class.for_child([["--out", "100%-%{n}.log"]], "4")).to eq(["--out", "100%-4.log"])
    end
  end
end
