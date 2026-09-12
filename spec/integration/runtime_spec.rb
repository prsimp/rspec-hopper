# frozen_string_literal: true

# Worker runtime behaviour over real processes: retry state isolation,
# requeue eligibility, per-process suite hooks, completion with idle workers
# and the invariants every finished build satisfies.
RSpec.describe "rspec-hopper work runtime", :integration, :redis do
  describe "retry state isolation (fails-first-passes-second, one worker)" do
    let(:unit) { "./spec/retry_spec.rb" }
    let(:example_ids) { ["#{unit}[1:1]", "#{unit}[1:2]"] }

    it "re-runs the unit in the same process and reports the second attempt as a clean pass" do
      worker = spawn_worker(fixture: "fails-first-passes-second", worker_id: "w1",
                            args: ["--max-requeues", "1", "--requeue-tolerance", "1"],
                            env: state_env, extra_rspec_args: json_format_args("w1.json"))
      worker.wait(timeout: 30)
      expect(worker.exit_code).to eq(0), worker.stderr
      expect(worker.stdout).to include("[hopper w1] Retrying #{unit} (retry 1 of 1; next attempt 2): 1 failure")

      log = attempt_log
      requeued = events("requeued", unit_id: unit)
      expect(requeued.size).to eq(1)
      expect(requeued.first).to include("retry_index" => 1, "worker_id" => "w1", "failure_summary" => "1 failure")
      finals = log.finalized_events(unit)
      expect(finals.size).to eq(1)
      expect(finals.first).to include("outcome" => "passed", "retry_index" => 1, "worker_id" => "w1")

      # Both attempts were delivered to the one worker process, so the second
      # attempt necessarily ran in the same PID as the first.
      deliveries = events("delivered", unit_id: unit)
      expect(deliveries.map { |e| e["worker_id"] }).to eq(%w[w1 w1])
      expect(deliveries.map { |e| e["retry_index"] }).to eq([0, 1])
      expect(deliveries.map { |e| e["stream"] }).to eq(["units", "units:priority"])

      # Formatters saw only the final attempt: each example exactly once, passed.
      examples = read_json(out_path("w1.json")).fetch("examples")
      expect(examples.map { |e| e["id"] }).to match_array(example_ids)
      expect(examples.map { |e| e["status"] }.uniq).to eq(["passed"])
      expect(read_json(out_path("w1.json")).dig("summary", "failure_count")).to eq(0)

      report = run_report(args: ["--summary-out", summary_path])
      expect(report.exit_code).to eq(0), report.stdout
      expect(summary["flaky"]).to eq([unit])
      expect(summary["retry_counts"]).to eq(unit => 1)
      expect(report.stdout).to include("flaky (passed after requeue): #{unit}")
      expect_consistent_build
    end
  end

  describe "requeue eligibility (mixed-requeueable-and-exit)" do
    let(:unit) { "./spec/mixed_spec.rb" }

    it "finalizes the unit as a test_failure on the first attempt and never requeues it" do
      worker = spawn_worker(fixture: "mixed-requeueable-and-exit", worker_id: "w1",
                            args: ["--max-requeues", "3", "--requeue-tolerance", "1"])
      worker.wait(timeout: 30)
      expect(worker.exit_code).to eq(0), worker.stderr

      expect(events("requeued")).to be_empty
      finals = attempt_log.finalized_events(unit)
      expect(finals.size).to eq(1)
      expect(finals.first).to include("outcome" => "failed", "reason" => "test_failure", "retry_index" => 0,
                                      "ownership_generation" => 1)
      expect(unit_states.fetch(unit)).to include("retry_index" => 0, "entered_retry" => false)

      report = run_report(args: ["--summary-out", summary_path])
      expect(report.exit_code).to eq(1), report.stdout
      expect(summary["verdict"]).to eq("failed")
      expect(summary["failed"].map { |f| f.values_at("unit_id", "reason") }).to eq([[unit, "test_failure"]])
      expect(summary["flaky"]).to be_empty
      expect_consistent_build
    end
  end

  describe "per-process suite hooks (before-suite-counter)" do
    it "runs before(:suite) once per worker process: three workers, three markers" do
      handles = spawn_workers(3, fixture: "before-suite-counter", env: state_env)
      codes = wait_all(handles, timeout: 30)
      expect(codes).to eq("w1" => 0, "w2" => 0, "w3" => 0)

      markers = Dir.children(state_dir).grep(/\Asuite-\d+\z/)
      expect(markers.size).to eq(3)
      expect(markers.map { |m| m[/\d+/].to_i }).to match_array(handles.values.map(&:pid))
      expect_consistent_build
    end
  end

  describe "completion with idle workers (slow-but-legitimate, three workers)" do
    let(:slow_env) { { "HOPPER_FIXTURE_SLEEP" => "6" } }
    let(:slow_args) { ["--timeout", "2"] }

    def wait_for_two_idle_workers
      wait_until(timeout: 10, message: "the slow unit to be held and two workers to be idle") do
        holder = holder_of(HopperSpec::Integration::SLOW_UNIT)
        holder && idle_worker_ids.size == 2 && finalized_count == 1
      end
    end

    it "keeps idle workers alive and refreshing liveness until the last unit finalizes, then all exit 0" do
      handles = spawn_workers(3, fixture: "slow-but-legitimate", args: slow_args, env: slow_env)
      wait_for_two_idle_workers
      holder = holder_of(HopperSpec::Integration::SLOW_UNIT)
      idle = idle_worker_ids
      expect(idle).not_to include(holder)

      # Idle workers refresh last_seen every loop iteration while the holder is busy.
      before = workers.slice(*idle).transform_values { |w| w["last_seen"] }
      wait_until(timeout: 5, message: "idle workers to refresh last_seen") do
        expect(complete?).to be(false)
        expect(idle.map { |wid| handles[wid].alive? }).to all(be(true))
        now = workers.slice(*idle).transform_values { |w| w["last_seen"] }
        idle.all? { |wid| now[wid] > before[wid] }
      end
      expect(finalized_count).to eq(1)

      codes = wait_all(handles, timeout: 30)
      expect(codes).to eq("w1" => 0, "w2" => 0, "w3" => 0)
      expect(events("reclaimed")).to be_empty
      expect(attempt_log.finalized_events(HopperSpec::Integration::SLOW_UNIT).first)
        .to include("outcome" => "passed", "worker_id" => holder)
      expect_consistent_build
    end

    it "lets an idle worker reclaim the last unit when its holder is SIGKILLed" do
      handles = spawn_workers(3, fixture: "slow-but-legitimate", args: slow_args, env: slow_env)
      wait_for_two_idle_workers
      holder = holder_of(HopperSpec::Integration::SLOW_UNIT)
      killed = handles.fetch(holder)
      killed.kill("KILL")
      killed.wait(timeout: 5)
      expect(killed.signaled?).to be(true)
      expect(killed.termsig).to eq(Signal.list.fetch("KILL"))

      reclaimed = wait_for_event("reclaimed", unit_id: HopperSpec::Integration::SLOW_UNIT, timeout: 10)
      expect(reclaimed.size).to eq(1)
      expect(reclaimed.first).to include("previous_worker_id" => holder, "reclaim_count" => 1, "retry_index" => 0,
                                         "ownership_generation" => 2, "stream" => "units")
      expect(reclaimed.first["worker_id"]).not_to eq(holder)

      survivors = handles.reject { |wid, _h| wid == holder }
      expect(wait_all(survivors, timeout: 30).values).to all(eq(0))
      final = attempt_log.finalized_events(HopperSpec::Integration::SLOW_UNIT)
      expect(final.size).to eq(1)
      expect(final.first).to include("outcome" => "passed", "worker_id" => reclaimed.first["worker_id"],
                                     "reclaim_count" => 1)
      expect(attempt_log.flaky).to be_empty
      expect(unit_states.fetch(HopperSpec::Integration::SLOW_UNIT)).to include("reclaim_count" => 1,
                                                                               "retry_index" => 0)
      report = run_report(args: ["--summary-out", summary_path])
      expect(report.exit_code).to eq(0), report.stdout
      expect(summary["reclaim_counts"]).to eq(HopperSpec::Integration::SLOW_UNIT => 1)
      expect_consistent_build
    end
  end

  describe "a suite that selects nothing (zero-examples)" do
    it "publishes an empty manifest, exits the workers 0 and fails the report unless --allow-empty" do
      handles = spawn_workers(2, fixture: "zero-examples")
      expect(wait_all(handles, timeout: 30)).to eq("w1" => 0, "w2" => 0)

      # An empty queue is not completion: the build is complete because
      # finalized_count reached total_units, which happens to be zero.
      man = manifest
      expect(man.total_units).to eq(0)
      expect(man.total_examples).to eq(0)
      expect(man.file_args).to eq(["spec"])
      expect(man.load_errors).to be_empty
      expect(queue.status).to be_ready
      expect(finalized_count).to eq(0)
      expect(events("delivered")).to be_empty
      expect(events("worker_error")).to be_empty

      report = run_report(args: ["--summary-out", summary_path])
      expect(report.exit_code).to eq(1), report.stdout
      expect(report.stdout).to include("1 file given, 0 examples selected")
      expect(summary).to include("verdict" => "failed", "total_units" => 0, "total_examples" => 0,
                                 "finalized_count" => 0)

      allowed = run_report(args: ["--allow-empty"])
      expect(allowed.exit_code).to eq(0), allowed.stdout
      expect(allowed.stdout).to include("passed")
      expect_consistent_build
    end
  end

  describe "every finished build (property-style, two workers each)" do
    fixtures = {
      "all-pass" => { exit: 0, units: 3, examples: 7 },
      "multiple-top-level-groups" => { exit: 0, units: 1, examples: 5 },
      "before-all-hook" => { exit: 0, units: 1, examples: 3 },
      "tag-filtered-selection" => { exit: 0, units: 2, examples: 3, rspec_args: ["--tag", "fast"],
                                    file_counts: { "./spec/fast_spec.rb" => 2, "./spec/mixed_spec.rb" => 1 } },
      "one-hard-failure" => { exit: 1, units: 2, examples: 3 }
    }

    fixtures.each do |fixture, expected|
      it "#{fixture}: every unit finalized exactly once, counts match, report exits #{expected[:exit]}" do
        handles = spawn_workers(2, fixture: fixture, extra_rspec_args: expected.fetch(:rspec_args, []))
        expect(wait_all(handles, timeout: 30)).to eq("w1" => 0, "w2" => 0)

        man = manifest
        expect(man.total_units).to eq(expected[:units])
        expect(man.total_examples).to eq(expected[:examples])
        expect(man.file_counts).to eq(expected[:file_counts]) if expected[:file_counts]
        expect(finalized_count).to eq(expected[:units])
        expect(attempt_log.exactly_one_finalized?(man.unit_ids)).to be(true)

        report = run_report(args: ["--summary-out", summary_path])
        expect(report.exit_code).to eq(expected[:exit]), report.stdout
        expect(summary).to include("total_units" => expected[:units], "total_examples" => expected[:examples],
                                   "finalized_count" => expected[:units])
        expect_consistent_build
      end
    end
  end
end
