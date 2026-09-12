# frozen_string_literal: true

RSpec.describe RSpec::Hopper::Worker::Suite do
  let(:files) do
    {
      "spec/two_groups_spec.rb" => <<~RUBY,
        RSpec.describe "first group" do
          it("one") { expect(1).to eq(1) }
          it("two") { expect(2).to eq(2) }
        end
        RSpec.describe "second group" do
          it("three") { expect(3).to eq(3) }
        end
      RUBY
      "spec/nested_spec.rb" => <<~RUBY,
        RSpec.describe "nested" do
          it("top") { expect(1).to eq(1) }
          context "inner" do
            it("deep") { expect(1).to eq(1) }
            it("slow one", :slow) { expect(1).to eq(1) }
          end
        end
      RUBY
      "spec/all_slow_spec.rb" => <<~RUBY,
        RSpec.describe "all slow", :slow do
          it("a") { expect(1).to eq(1) }
        end
      RUBY
      "spec/empty_spec.rb" => "RSpec.describe('empty') {}\n",
      "spec/models/model_spec.rb" => HopperSpec::RSpecSandbox::PASSING_SPEC
    }
  end

  describe ".load" do
    it "discovers one unit per file with selected examples, in RSpec's order, with ./spec ids" do
      with_project(files) do
        suite = load_suite(["--order", "defined"])
        expect(suite.unit_ids).to eq(%w[./spec/all_slow_spec.rb ./spec/models/model_spec.rb ./spec/nested_spec.rb
                                        ./spec/two_groups_spec.rb])
        expect(suite.units).to all(be_a(RSpec::Hopper::Unit).and(have_attributes(type: "file")))
        expect(suite.file_counts).to eq("./spec/all_slow_spec.rb" => 1, "./spec/models/model_spec.rb" => 2,
                                        "./spec/nested_spec.rb" => 3, "./spec/two_groups_spec.rb" => 3)
        expect(suite.total_examples).to eq(9)
        expect(suite.example_ids).to all(start_with("./spec/"))
        expect(suite.example_ids.size).to eq(9)
        expect(suite.load_errors).to eq([])
        expect(suite.file_args).to eq(["spec"])
        expect(suite.fingerprint).to be_a(RSpec::Hopper::Fingerprint)
        expect(suite.runner).to be_a(RSpec::Hopper::Worker::Runner)
      end
    end

    it "keeps every top-level group of a file together and exposes the selected examples" do
      with_project(files) do
        suite = load_suite
        groups = suite.groups_for("./spec/two_groups_spec.rb")
        expect(groups.map(&:description)).to eq(["first group", "second group"])
        expect(groups).to all(satisfy { |g| g.metadata[:file_path] == "./spec/two_groups_spec.rb" })
        expect(suite.examples_for("./spec/nested_spec.rb").map(&:description)).to eq(["top", "deep", "slow one"])
        expect(suite.groups_for("./spec/unknown_spec.rb")).to eq([])
      end
    end

    it "excludes files with zero selected examples after tag filtering" do
      with_project(files) do
        suite = load_suite(["--tag", "~slow"])
        expect(suite.unit_ids).not_to include("./spec/all_slow_spec.rb", "./spec/empty_spec.rb")
        expect(suite.file_counts["./spec/nested_spec.rb"]).to eq(2)
        expect(suite.total_examples).to eq(7)
        expect(suite.example_ids).not_to include("./spec/nested_spec.rb[1:2:2]")
      end
    end

    it "applies line-number and --example filtering to counts and ids" do
      with_project(files) do
        suite = load_suite(["spec/two_groups_spec.rb:3"])
        expect(suite.unit_ids).to eq(["./spec/two_groups_spec.rb"])
        expect(suite.file_counts).to eq("./spec/two_groups_spec.rb" => 1)
        expect(suite.example_ids).to eq(["./spec/two_groups_spec.rb[1:2]"])
        expect(suite.file_args).to eq(["spec/two_groups_spec.rb:3"])
      end
      with_project(files) do
        suite = load_suite(["--example", "deep"])
        expect(suite.unit_ids).to eq(["./spec/nested_spec.rb"])
        expect(suite.total_examples).to eq(1)
      end
    end

    it "loads nothing and reports no units for an empty selection" do
      with_project(files) do
        suite = load_suite(["--tag", "nonexistent"])
        expect(suite.units).to eq([])
        expect(suite.total_examples).to eq(0)
        expect(suite.load_errors).to eq([])
      end
    end

    it "captures load errors instead of raising" do
      bad = files.merge("spec/bad_spec.rb" => "RSpec.describe('bad') { raise 'kaboom at load' }\n",
                        "spec/syntax_spec.rb" => "RSpec.describe('syntax') do\n  it('x') {\nend\n")
      with_project(bad) do
        suite = load_suite
        expect(suite.load_errors.size).to eq(2)
        expect(suite.load_errors.join).to include("An error occurred while loading ./spec/bad_spec.rb")
          .and include("kaboom at load")
          .and include("./spec/syntax_spec.rb")
        expect(suite.fingerprint).to be_a(RSpec::Hopper::Fingerprint)
      end
    end

    it "raises BootError when RSpec cannot apply its options" do
      with_project(files) do
        out = StringIO.new
        expect { load_suite(["--require", "does_not_exist_anywhere"], out: out) }
          .to raise_error(RSpec::Hopper::BootError, /--require/)
        expect(out.string).to include("does_not_exist_anywhere")
      end
    end

    it "raises BootError for other boot failures" do
      with_project(files) do
        allow(RSpec::Core::ConfigurationOptions).to receive(:new).and_raise(TypeError, "bad args")
        expect { load_suite }.to raise_error(RSpec::Hopper::BootError, /TypeError: bad args/)
      end
    end
  end

  describe "unsupported options" do
    {
      "--fail-fast" => ["--fail-fast"], "--fail-fast=3" => ["--fail-fast=3"], "--only-failures" => ["--only-failures"],
      "--next-failure" => ["--next-failure"], "--bisect" => ["--bisect"], "--dry-run" => ["--dry-run"],
      "--drb" => ["--drb"], "--init" => ["--init"]
    }.each do |label, args|
      it "rejects #{label} on the command line" do
        with_project(files) do
          expect { load_suite(args) }
            .to raise_error(RSpec::Hopper::UnsupportedOption, /#{Regexp.escape(label.split("=").first)}/)
        end
      end
    end

    it "rejects --fail-fast coming from the project's .rspec file" do
      with_project(files, dot_rspec: "--fail-fast\n--color\n") do
        expect { load_suite }.to raise_error(RSpec::Hopper::UnsupportedOption, /--fail-fast/)
      end
    end

    it "rejects --fail-fast and --init coming from SPEC_OPTS" do
      with_project(files) do
        ENV["SPEC_OPTS"] = "--fail-fast"
        expect { load_suite }.to raise_error(RSpec::Hopper::UnsupportedOption, /--fail-fast/)
        ENV["SPEC_OPTS"] = "--init"
        expect { load_suite }.to raise_error(RSpec::Hopper::UnsupportedOption, /--init/)
      end
    end

    it "rejects --fail-fast set by a required helper" do
      helper = files.merge("spec/spec_helper.rb" => "RSpec.configure { |c| c.fail_fast = true }\n")
      with_project(helper, dot_rspec: "--require ./spec/spec_helper\n") do
        expect { load_suite }.to raise_error(RSpec::Hopper::UnsupportedOption, /--fail-fast/)
      end
    end
  end

  describe "#adopt_seed" do
    it "sets the seed without switching a defined ordering to random" do
      with_project(files) do
        suite = load_suite
        registry = suite.configuration.ordering_registry
        strategy = registry.fetch(:global)
        expect(suite.adopt_seed(4242)).to eq(4242)
        expect(suite.configuration.seed).to eq(4242)
        expect(registry.fetch(:global)).to equal(strategy)
        expect(suite.configuration.seed_used?).to be(false)
      end
    end

    it "replaces the seed of a random ordering" do
      with_project(files) do
        suite = load_suite(["--seed", "1"])
        expect(suite.configuration.seed).to eq(1)
        suite.seed = 99
        expect(suite.configuration.seed).to eq(99)
        expect(suite.configuration.ordering_registry.fetch(:global)).to be_a(RSpec::Core::Ordering::Random)
        expect(suite.adopt_seed(nil)).to be_nil
        expect(suite.configuration.seed).to eq(99)
      end
    end
  end

  describe "#apply_formatter_args" do
    it "adds the formatter pairs to the configured RSpec and ignores other arguments" do
      with_project(files) do
        suite = load_suite
        entries = suite.apply_formatter_args(["--format", "json", "--out", "tmp/out.json", "-f", "documentation",
                                              "--tag", "fast", "spec"])
        expect(entries).to eq([["json", "tmp/out.json"], ["documentation"]])
        expect(suite.configuration.formatters.map { |f| f.class.name })
          .to eq(%w[RSpec::Core::Formatters::JsonFormatter RSpec::Core::Formatters::DocumentationFormatter])
      end
    end

    it "attaches a lone --out to the default progress formatter" do
      with_project(files) do
        expect(load_suite.apply_formatter_args(["--out", "tmp/p.txt"])).to eq([["progress", "tmp/p.txt"]])
      end
    end
  end

  describe "#to_manifest" do
    it "builds the manifest from the loaded suite" do
      with_project(files) do
        suite = load_suite(["--seed", "17"], config: work_config(revision: "rev1"))
        manifest = suite.to_manifest
        expect(manifest).to have_attributes(total_units: 4, total_examples: 9, file_args: ["spec"], seed: 17,
                                            revision: "rev1", load_errors: [], fingerprint: suite.fingerprint.value)
        expect(manifest.unit_ids).to eq(suite.unit_ids)
        expect(manifest.ready_at).to be_nil
      end
    end
  end

  describe ".runner_wrappers" do
    let(:wrapped) do
      mod = Module.new do
        def run_specs(*) = super
      end
      Class.new { const_set(:Wrapper, mod) }.tap { |klass| klass.prepend(mod) }
    end

    it "names the modules prepended onto the class that define run_specs" do
      expect(described_class.runner_wrappers(wrapped).size).to eq(1)
    end

    it "ignores a prepended module that leaves run_specs alone" do
      klass = Class.new { prepend(Module.new { def setup(*) = super }) }
      expect(described_class.runner_wrappers(klass)).to be_empty
    end

    it "finds nothing on a bare RSpec runner subclass, which is the point" do
      expect(described_class.runner_wrappers(Class.new(RSpec::Core::Runner))).to be_empty
    end
  end

  describe "instrumentation that wraps Runner#run_specs" do
    it "warns that the wrapper will not run and names the before(:suite) route" do
      allow(described_class).to receive(:runner_wrappers).and_return(["Datadog::CI::Contrib::RSpec::Runner::InstanceMethods"])
      err = StringIO.new
      with_project(files) { load_suite([], err: err) }

      expect(err.string).to include("Datadog::CI::Contrib::RSpec::Runner::InstanceMethods wraps " \
                                    "RSpec::Core::Runner#run_specs, which rspec-hopper replaces")
      expect(err.string).to include("before(:suite)")
    end

    it "says nothing when no such instrumentation is loaded" do
      # Stubbed rather than read from the live class: the datadog contract spec
      # prepends onto RSpec::Core::Runner for the rest of the process, so what
      # this process has loaded depends on file order.
      allow(described_class).to receive(:runner_wrappers).and_return([])
      err = StringIO.new
      with_project(files) { load_suite([], err: err) }
      expect(err.string).to be_empty
    end
  end
end
