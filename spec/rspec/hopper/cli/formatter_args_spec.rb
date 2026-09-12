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

  describe ".entries" do
    it "attaches an --out to the preceding --format" do
      pairs = [%w[--format json], %w[--out a.json], %w[--format doc]]
      expect(described_class.entries(pairs)).to eq([["json", "a.json"], ["doc", nil]])
    end

    it "attaches a lone --out to the default progress formatter" do
      expect(described_class.entries([%w[--out p.txt]])).to eq([["progress", "p.txt"]])
    end

    it "is empty when there are no formatter options" do
      expect(described_class.entries([])).to eq([])
    end
  end

  describe ".defaults_needed?" do
    it "is true when a formatter has no --out of its own" do
      expect(described_class.defaults_needed?([%w[--format json]])).to be(true)
    end

    it "is true when there are no formatter options at all" do
      expect(described_class.defaults_needed?([])).to be(true)
    end

    it "is false when every formatter already writes to a file" do
      expect(described_class.defaults_needed?([%w[--format json], %w[--out a.json]])).to be(false)
    end
  end

  describe ".for_child" do
    let(:pairs) { [%w[--format json], ["--out", "tmp/%{n}/report-%{n}.json"], %w[--format doc]] }

    it "substitutes %{n} in --out paths with the child's TEST_ENV_NUMBER" do
      expect(described_class.for_child(pairs, "2", label: "w.2"))
        .to eq(%w[--format json --out tmp/2/report-2.json --format doc --out tmp/rspec-hopper/w-2-doc.txt])
    end

    it "substitutes the empty string for the first child" do
      expect(described_class.for_child(pairs, "", label: "w.1"))
        .to eq(%w[--format json --out tmp//report-.json --format doc --out tmp/rspec-hopper/w-1-doc.txt])
    end

    it "gives every formatter a file when none was asked for, so children never share the console" do
      expect(described_class.for_child([], "2", label: "w.2"))
        .to eq(%w[--format progress --out tmp/rspec-hopper/w-2-progress.txt])
    end

    it "names generated files after the formatter's own file format" do
      expect(described_class.for_child([%w[--format json]], "", label: "w.1"))
        .to eq(%w[--format json --out tmp/rspec-hopper/w-1-json.json])
      expect(described_class.for_child([%w[--format html]], "", label: "w.1"))
        .to eq(%w[--format html --out tmp/rspec-hopper/w-1-html.html])
    end

    it "numbers repeated formatters so one child never overwrites its own output" do
      expect(described_class.for_child([%w[--format json], %w[--format json]], "", label: "w.1"))
        .to eq(%w[--format json --out tmp/rspec-hopper/w-1-json.json
                  --format json --out tmp/rspec-hopper/w-1-json-2.json])
    end

    it "honours a caller-chosen directory" do
      expect(described_class.for_child([], "", label: "w.1", dir: "log/hopper"))
        .to eq(%w[--format progress --out log/hopper/w-1-progress.txt])
    end

    it "falls back to the env number when there is no label" do
      expect(described_class.for_child([],
                                       "3")).to eq(%w[--format progress --out tmp/rspec-hopper/worker3-progress.txt])
    end

    it "leaves --format values and paths without a placeholder alone" do
      expect(described_class.for_child([["--format", "%{n}"], %w[--out plain.xml]], "3", label: "w.3"))
        .to eq(["--format", "%{n}", "--out", "plain.xml"])
    end

    it "treats the placeholder literally even next to other percent signs" do
      expect(described_class.for_child([["--out", "100%-%{n}.log"]], "4", label: "w.4"))
        .to eq(%w[--format progress --out 100%-4.log])
    end
  end
end
