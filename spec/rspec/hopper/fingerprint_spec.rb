# frozen_string_literal: true

RSpec.describe RSpec::Hopper::Fingerprint do
  let(:inputs) do
    { "file_args" => ["spec"], "filter" => { "inclusions" => [], "exclusions" => [] }, "pattern" => "**/*_spec.rb",
      "exclude_pattern" => "", "order" => "defined", "example_ids" => ["./spec/a_spec.rb[1:1]"], "revision" => nil }
  end

  describe ".ordering_name" do
    it "strips the seed and normalizes random" do
      expect(described_class.ordering_name("rand:123")).to eq("random")
      expect(described_class.ordering_name("random")).to eq("random")
      expect(described_class.ordering_name("defined")).to eq("defined")
      expect(described_class.ordering_name("recently-modified")).to eq("recently-modified")
      expect(described_class.ordering_name(nil)).to eq("defined")
    end
  end

  describe ".render_rules" do
    it "renders rules as sorted strings without proc addresses or the project directory" do
      rules = { locations: { File.expand_path("spec/a_spec.rb") => [3] }, if: proc {}, focus: true }
      rendered = described_class.render_rules(rules)
      expect(rendered).to eq(rendered.sort)
      expect(rendered.join).not_to match(/0x[0-9a-f]+/)
      expect(rendered.join).not_to include(File.expand_path("."))
      expect(rendered).to include('locations={"./spec/a_spec.rb" => [3]}')
    end
  end

  describe "#value" do
    it "is a SHA256 hex digest that is stable for equal inputs" do
      first = described_class.new(inputs)
      second = described_class.new(inputs.dup)
      expect(first.value).to match(/\A[0-9a-f]{64}\z/)
      expect(first).to eq(second)
      expect(first).to eq(second.value)
    end

    it "does not depend on hash key order or symbol keys" do
      reordered = inputs.to_a.reverse.to_h.transform_keys(&:to_sym)
      expect(described_class.new(reordered).value).to eq(described_class.new(inputs).value)
    end

    it "changes when the selected example ids change" do
      other = inputs.merge("example_ids" => ["./spec/a_spec.rb[1:2]"])
      expect(described_class.new(other).value).not_to eq(described_class.new(inputs).value)
    end
  end

  describe "Mismatch.explain" do
    let(:local) { described_class.new(inputs) }

    it "shows both values and a local summary when remote inputs are unknown" do
      message = described_class::Mismatch.explain(local, "abc123")
      expect(message).to include(local.value).and include("abc123")
      expect(message).to include("local inputs: file_args=[\"spec\"]").and include("example_ids=1")
    end

    it "names the differing inputs and counts differing example ids when remote inputs are available" do
      remote = inputs.merge("file_args" => ["spec/models"],
                            "example_ids" => ["./spec/a_spec.rb[1:1]", "./spec/b_spec.rb[1:1]",
                                              "./spec/c_spec.rb[1:1]"])
      message = described_class::Mismatch.explain(local, "abc123", JSON.generate(remote))
      expect(message).to include("differing inputs: file_args, example_ids")
      expect(message).to include('file_args: local=["spec"] remote=["spec/models"]')
      expect(message).to include("example_ids: 2 differ (local 1, remote 3)")
    end

    it "tolerates unparseable remote inputs" do
      expect(described_class::Mismatch.explain(local, "abc", "not json")).to include("local inputs:")
    end
  end

  describe ".compute" do
    let(:files) do
      { "spec/a_spec.rb" => <<~RUBY, "spec/b_spec.rb" => HopperSpec::RSpecSandbox::PASSING_SPEC }
        RSpec.describe "a" do
          it("fast") { expect(1).to eq(1) }
          it("slow", :slow) { expect(1).to eq(1) }
        end
      RUBY
    end

    def fingerprint_for(args, revision: nil)
      with_project(files) { load_suite(args, config: work_config(revision: revision)).fingerprint }
    end

    it "is stable across loads of the same suite with the same arguments" do
      first = fingerprint_for([])
      second = fingerprint_for([])
      expect(first.value).to eq(second.value)
    end

    it "ignores the seed but not the ordering strategy" do
      expect(fingerprint_for(["--seed", "1"]).value).to eq(fingerprint_for(["--seed", "2"]).value)
      expect(fingerprint_for(["--order", "defined"]).value).not_to eq(fingerprint_for(["--order", "rand"]).value)
      expect(fingerprint_for(["--order", "defined"]).inputs["order"]).to eq("defined")
      expect(fingerprint_for(["--seed", "1"]).inputs["order"]).to eq("random")
    end

    it "changes with tag filters, file arguments, example filters and the revision" do
      base = fingerprint_for([])
      expect(fingerprint_for(["--tag", "~slow"]).value).not_to eq(base.value)
      expect(fingerprint_for(["spec/a_spec.rb"]).value).not_to eq(base.value)
      expect(fingerprint_for(["--example", "fast"]).value).not_to eq(base.value)
      expect(fingerprint_for(["spec/a_spec.rb:3"]).value).not_to eq(fingerprint_for(["spec/a_spec.rb"]).value)
      expect(fingerprint_for([], revision: "abc").value).not_to eq(base.value)
    end

    it "records normalized inputs" do
      inputs = fingerprint_for(["--tag", "~slow"]).inputs
      expect(inputs["file_args"]).to eq(["spec"])
      expect(inputs["filter"]["exclusions"]).to include("slow=true")
      expect(inputs["example_ids"]).to eq(["./spec/a_spec.rb[1:1]", "./spec/b_spec.rb[1:1]", "./spec/b_spec.rb[1:2]"])
    end
  end
end
