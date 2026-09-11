# frozen_string_literal: true

RSpec.describe RSpec::Hopper::CIEnv do
  it "returns nil for both ids outside any supported CI" do
    expect(described_class.build_id({})).to be_nil
    expect(described_class.worker_id({})).to be_nil
  end

  it "infers CircleCI ids from the workflow id and node index" do
    env = { "CIRCLECI" => "true", "CIRCLE_WORKFLOW_ID" => "wf-1", "CIRCLE_BUILD_NUM" => "77",
            "CIRCLE_NODE_INDEX" => "3" }
    expect(described_class.build_id(env)).to eq("wf-1")
    expect(described_class.worker_id(env)).to eq("3")
  end

  it "falls back to CIRCLE_BUILD_NUM without a workflow id" do
    env = { "CIRCLECI" => "true", "CIRCLE_BUILD_NUM" => "77" }
    expect(described_class.build_id(env)).to eq("77")
    expect(described_class.worker_id(env)).to be_nil
  end

  it "infers Buildkite ids" do
    env = { "BUILDKITE" => "true", "BUILDKITE_BUILD_ID" => "bk-9", "BUILDKITE_PARALLEL_JOB" => "1" }
    expect(described_class.build_id(env)).to eq("bk-9")
    expect(described_class.worker_id(env)).to eq("1")
  end

  it "infers a GitHub Actions build id from run id and attempt, with no worker id" do
    env = { "GITHUB_ACTIONS" => "true", "GITHUB_RUN_ID" => "123", "GITHUB_RUN_ATTEMPT" => "2" }
    expect(described_class.build_id(env)).to eq("123-2")
    expect(described_class.worker_id(env)).to be_nil
  end

  it "assumes attempt 1 on GitHub Actions when the attempt is missing" do
    expect(described_class.build_id({ "GITHUB_ACTIONS" => "true", "GITHUB_RUN_ID" => "123" })).to eq("123-1")
  end

  it "infers GitLab ids" do
    env = { "GITLAB_CI" => "true", "CI_PIPELINE_ID" => "p-5", "CI_NODE_INDEX" => "2" }
    expect(described_class.build_id(env)).to eq("p-5")
    expect(described_class.worker_id(env)).to eq("2")
  end

  it "ignores vendor variables when the vendor's detection variable is absent" do
    expect(described_class.build_id({ "CIRCLE_WORKFLOW_ID" => "wf" })).to be_nil
  end

  it "treats blank values as absent" do
    expect(described_class.build_id({ "GITLAB_CI" => "true", "CI_PIPELINE_ID" => "  " })).to be_nil
  end

  it "builds the default worker id from hostname and pid" do
    expect(described_class.default_worker_id(hostname: "box", pid: 42)).to eq("box-42")
    expect(described_class.default_worker_id).to eq("#{Socket.gethostname}-#{Process.pid}")
  end

  it "documents every vendor's variables for the README" do
    expect(described_class::VARIABLES.map(&:first)).to eq(["CircleCI", "Buildkite", "GitHub Actions", "GitLab CI"])
    described_class::VARIABLES.each do |_name, detect, build_vars, worker_vars|
      expect(detect).to match(/\A[A-Z_]+\z/)
      expect(build_vars).not_to be_empty
      expect(worker_vars).to all(match(/\A[A-Z_]+\z/))
    end
  end
end
