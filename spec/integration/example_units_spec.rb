# frozen_string_literal: true

# `--unit example` over real processes: one queue entry per example, context
# hooks around each, a retry that reruns only the flaky example, example ids in
# the report, and the fingerprint rejecting a file-unit worker.
RSpec.describe "rspec-hopper work --unit example", :integration, :redis do
  let(:flaky) { "./spec/flaky_spec.rb[1:1]" }
  let(:hard) { "./spec/hard_spec.rb[1:1]" }
  let(:unit_ids) do
    %w[./spec/flaky_spec.rb[1:1] ./spec/flaky_spec.rb[1:2] ./spec/flaky_spec.rb[1:3:1]
       ./spec/hard_spec.rb[1:1] ./spec/hard_spec.rb[1:2]]
  end
  let(:example_args) { ["--unit", "example", "--max-requeues", "1", "--requeue-tolerance", "1"] }

  def before_all_runs = File.read(File.join(state_dir, "before-all-runs")).to_i

  it "publishes one unit per example, retries only the flaky example and reports example ids" do
    worker = spawn_worker(fixture: "example-units", worker_id: "w1", args: example_args, env: state_env,
                          extra_rspec_args: ["--order", "defined", *json_format_args("w1.json")])
    worker.wait(timeout: 30)
    expect(worker.exit_code).to eq(0), worker.stderr

    expect(manifest).to have_attributes(unit_type: "example", unit_ids: unit_ids, total_units: 5, total_examples: 5)
    expect(unit_states.keys).to match_array(unit_ids)
    expect(worker.stdout).to include("[hopper w1] Retrying #{flaky} (retry 1 of 1; next attempt 2): 1 failure")
    # Both failures are requeueable; the hard one exhausts its budget on the retry.
    expect(events("requeued").map { |e| e["unit_id"] }).to contain_exactly(flaky, hard)
    expect(attempt_log.finalized_events(flaky).first).to include("outcome" => "passed", "retry_index" => 1)
    expect(attempt_log.finalized_events(hard).first)
      .to include("outcome" => "failed", "reason" => "retry_budget_exhausted", "retry_index" => 1)
    # before(:all) ran once per unit of its file, plus once for the retry.
    expect(before_all_runs).to eq(4)

    expect(formatter_examples(out_path("w1.json"))).to eq(
      flaky => "passed", "./spec/flaky_spec.rb[1:2]" => "passed", "./spec/flaky_spec.rb[1:3:1]" => "passed",
      hard => "failed", "./spec/hard_spec.rb[1:2]" => "passed"
    )

    report = run_report(args: ["--summary-out", summary_path, "--failed-out", out_path("failed.txt")])
    expect(report.exit_code).to eq(1), report.stdout
    expect(summary).to include("verdict" => "failed", "unit_type" => "example", "total_units" => 5,
                               "flaky" => [flaky], "retry_counts" => { flaky => 1, hard => 1 })
    expect(summary["failed"].map { |f| f["unit_id"] }).to eq([hard])
    expect(File.read(out_path("failed.txt"))).to eq("#{hard}\n")
    expect(report.stdout).to include("units: 5 example units total, 5 finalized; examples: 5 selected")
    expect_consistent_build
  end

  it "shares the example units among three workers and completes with every unit finalized once" do
    handles = spawn_workers(3, fixture: "example-units", args: example_args, env: state_env)
    codes = wait_all(handles, timeout: 30)
    expect(codes).to eq("w1" => 0, "w2" => 0, "w3" => 0)
    expect(manifest.unit_ids).to match_array(unit_ids)
    expect(events("requeued").map { |e| e["unit_id"] }).to contain_exactly(flaky, hard)
    expect(attempt_log.flaky).to eq([flaky])
    expect(before_all_runs).to eq(4)
    expect(attempt_log.failed.map { |f| f[:unit_id] }).to eq([hard])
    expect_consistent_build
  end

  it "rejects a file-unit worker that joins an example-unit build, naming the unit type" do
    first = spawn_worker(fixture: "example-units", worker_id: "w1", args: ["--unit", "example"], env: state_env)
    wait_for_ready
    second = spawn_worker(fixture: "example-units", worker_id: "w2", env: state_env)
    second.wait(timeout: 30)
    expect(second.exit_code).to eq(2)
    expect(second.stderr).to include("suite fingerprint mismatch").and include("differing inputs: unit_type")
    expect(second.stderr).to include("unit_type=file")
    first.wait(timeout: 30)
    expect(first.exit_code).to eq(0), first.stderr
    expect(events("worker_error").map { |e| e["worker_id"] }).to eq(["w2"])
    expect_consistent_build
  end
end
