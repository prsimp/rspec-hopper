# frozen_string_literal: true

# `rspec-hopper report` timing: inactivity is measured from the latest
# heartbeat, not from the last finalization, and the initialization wait
# lets the report start before any worker.
RSpec.describe "rspec-hopper report timing", :integration, :redis do
  let(:slow_unit) { HopperSpec::Integration::SLOW_UNIT }

  describe "inactivity (slow-but-legitimate, one worker, --inactive-timeout shorter than the unit)" do
    # Worker heartbeats every --timeout / 3 = 1 s; the unit takes 6 s; the
    # report gives up after 2 s without activity.
    let(:worker_args) { ["--timeout", "3"] }
    let(:slow_env) { { "HOPPER_FIXTURE_SLEEP" => "6" } }
    let(:report_args) { ["--inactive-timeout", "2", "--init-timeout", "15", "--summary-out", summary_path] }

    it "does not exit 3 while heartbeats refresh last_seen" do
      worker = spawn_worker(fixture: "slow-but-legitimate", worker_id: "w1", args: worker_args, env: slow_env)
      wait_for_holder(slow_unit)
      report = spawn_report(args: report_args)
      report.wait(timeout: 30)
      expect(report.exit_code).to eq(0), report.stdout
      expect(summary).to include("verdict" => "passed", "finalized_count" => 2, "total_units" => 2)
      expect(summary["never_finalized"]).to be_empty

      worker.wait(timeout: 10)
      expect(worker.exit_code).to eq(0), worker.stderr
      expect_consistent_build
    end

    it "exits 3 after --inactive-timeout measured from the last heartbeat when every worker is SIGKILLed" do
      worker = spawn_worker(fixture: "slow-but-legitimate", worker_id: "w1", args: worker_args, env: slow_env)
      wait_for_holder(slow_unit)
      report = spawn_report(args: report_args)
      wait_until(timeout: 5, message: "the report to start polling") { report.alive? }

      worker.kill("KILL")
      worker.wait(timeout: 5)
      expect(worker.signaled?).to be(true)
      last_seen = workers.fetch("w1").fetch("last_seen")

      report.wait(timeout: 30)
      finished_at = epoch_ms
      expect(report.exit_code).to eq(3), report.stdout
      expect(workers.fetch("w1").fetch("last_seen")).to eq(last_seen)
      # Inactivity counts from the dead worker's last heartbeat: at least the
      # 2 s window, and not much more than the window plus the report's 1 s poll.
      expect(finished_at - last_seen).to be >= 2000
      expect(finished_at - last_seen).to be < 6000

      expect(report.stdout).to include("incomplete: workers inactive for")
      expect(report.stdout).to include("never finalized: #{slow_unit} (last worker w1)")
      expect(summary).to include("verdict" => "incomplete", "exit_code" => 3)
      expect(summary["never_finalized"]).to include("unit_id" => slow_unit, "last_worker_id" => "w1")
      expect(summary["finalized_count"]).to be < summary["total_units"]
      expect(attempt_log.finalized_events(slow_unit)).to be_empty
    end
  end

  describe "ordering" do
    it "started before any worker, waits through initialization and returns the verdict" do
      report = spawn_report(args: ["--init-timeout", "20", "--summary-out", summary_path])
      wait_until(timeout: 5, message: "the report to start polling") { report.alive? }
      expect(queue.status.present?).to be(false)

      worker = spawn_worker(fixture: "all-pass", worker_id: "w1")
      report.wait(timeout: 30)
      expect(report.exit_code).to eq(0), report.stdout
      expect(report.stdout).to include("units: 3 total, 3 finalized; examples: 7 selected")
      expect(summary).to include("verdict" => "passed", "total_units" => 3, "total_examples" => 7,
                                 "finalized_count" => 3, "state" => "ready")

      worker.wait(timeout: 10)
      expect(worker.exit_code).to eq(0), worker.stderr
      expect_consistent_build
    end

    it "exits 2 after --init-timeout against a build id nobody initializes" do
      started = monotonic
      report = run_report(args: ["--init-timeout", "2", "--summary-out", summary_path], timeout: 15)
      elapsed = monotonic - started
      expect(report.exit_code).to eq(2), report.stdout
      expect(elapsed).to be_between(2, 6)
      expect(report.stdout).to include("build #{build_id} never initialized")
      expect(summary).to include("verdict" => "missing", "exit_code" => 2, "total_units" => nil)
      expect(HopperSpec::RedisHelper.keys(redis, build_id)).to be_empty
    end
  end
end
