# frozen_string_literal: true

RSpec.describe RSpec::Hopper::CLI do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  def run(*argv)
    described_class.run(argv, out: out, err: err)
  end

  it "prints the version" do
    expect(run("--version")).to eq(0)
    expect(out.string).to eq("rspec-hopper #{RSpec::Hopper::VERSION}\n")
  end

  it "prints usage on --help and exits 0" do
    expect(run("--help")).to eq(0)
    expect(out.string).to include("Usage: rspec-hopper <command>")
    expect(err.string).to be_empty
  end

  it "prints usage to stderr and exits 2 with no command" do
    expect(run).to eq(2)
    expect(err.string).to include("no command given").and include("Usage:")
    expect(out.string).to be_empty
  end

  it "rejects an unknown command with usage and exit 2" do
    expect(run("bogus")).to eq(2)
    expect(err.string).to include('unknown command "bogus"').and include("Usage:")
  end

  it "dispatches work to CLI::Work.run with the remaining arguments" do
    allow(RSpec::Hopper::CLI::Work).to receive(:run).and_return(4)
    expect(run("work", "--build", "b", "--", "spec")).to eq(4)
    expect(RSpec::Hopper::CLI::Work).to have_received(:run).with(%w[--build b -- spec], out: out, err: err)
  end

  it "dispatches report to CLI::Report.run with the remaining arguments" do
    report = class_double(RSpec::Hopper::CLI::Report, run: 1)
    stub_const("RSpec::Hopper::CLI::Report", report)
    expect(run("report", "--build", "b")).to eq(1)
    expect(report).to have_received(:run).with(%w[--build b], out: out, err: err)
  end

  it "turns a UsageError from a subcommand into a message and exit 2" do
    allow(RSpec::Hopper::CLI::Work).to receive(:run).and_raise(RSpec::Hopper::UsageError, "--build is required")
    expect(run("work")).to eq(2)
    expect(err.string).to eq("rspec-hopper: --build is required\n")
  end

  it "prints a subcommand's help text to stdout and exits 0" do
    allow(RSpec::Hopper::CLI::Work).to receive(:run).and_raise(RSpec::Hopper::CLI::HelpRequested.new("work help"))
    expect(run("work", "-h")).to eq(0)
    expect(out.string).to eq("work help\n")
  end
end
