# frozen_string_literal: true

# Chaos: workers killed, stopped and hung at the worst moments. After every
# run `expect_consistent_build` checks the build's invariants: exactly one
# `finalized` per unit, finalized_count == total_units, a positive TTL on
# every key and unit_state.reclaim_count == the unit's `reclaimed` events.
RSpec.describe "rspec-hopper chaos", :integration, :redis do
  let(:slow_unit) { HopperSpec::Integration::SLOW_UNIT }
  let(:hang_unit) { HopperSpec::Integration::HANG_UNIT }
  let(:abort_unit) { HopperSpec::Integration::ABORT_UNIT }
  let(:flaky_unit) { HopperSpec::Integration::FLAKY_UNIT }
  let(:sigkill) { Signal.list.fetch("KILL") }

  def kill_and_reap(handle)
    handle.kill("KILL")
    handle.wait(timeout: 5)
    expect(handle.signaled?).to be(true)
    expect(handle.termsig).to eq(sigkill)
  end

  describe "(a) SIGKILL one of three workers mid-unit" do
    it "still exhausts the queue, reports correctly and leaves every key with a TTL" do
      # all-pass finishes in milliseconds, too fast to be caught mid-unit;
      # slow-but-legitimate's 3 s unit gives the kill a window.
      handles = spawn_workers(3, fixture: "slow-but-legitimate", args: ["--timeout", "2"],
                                 env: { "HOPPER_FIXTURE_SLEEP" => "3" })
      victim = wait_for_holder(slow_unit)
      kill_and_reap(handles.fetch(victim))

      survivors = handles.reject { |wid, _h| wid == victim }
      expect(wait_all(survivors, timeout: 30).values).to all(eq(0))
      reclaimed = events("reclaimed", unit_id: slow_unit)
      expect(reclaimed.size).to eq(1)
      expect(reclaimed.first).to include("previous_worker_id" => victim)
      expect(survivors.keys).to include(reclaimed.first["worker_id"])

      report = run_report(args: ["--summary-out", summary_path])
      expect(report.exit_code).to eq(0), report.stdout
      expect(summary).to include("verdict" => "passed", "finalized_count" => 2)
      expect(summary["reclaim_counts"]).to eq(slow_unit => 1)
      expect(summary["flaky"]).to be_empty
      expect(HopperSpec::RedisHelper.ttls(redis, build_id).values).to all(be_positive)
      expect_consistent_build
    end
  end

  describe "(b) SIGSTOP a worker mid-unit until a sibling reclaims and finishes the unit" do
    it "rejects the stale finalize with a stale_rejected event and the sibling's formatter shows the unit once" do
      handles = %w[w1 w2].to_h do |wid|
        [wid, spawn_worker(fixture: "slow-but-legitimate", worker_id: wid, args: ["--timeout", "2"],
                           env: { "HOPPER_FIXTURE_SLEEP" => "4" },
                           extra_rspec_args: json_format_args("#{wid}.json"))]
      end
      stopped = wait_for_holder(slow_unit)
      sibling = (handles.keys - [stopped]).first
      expect(handles.fetch(stopped).kill("STOP")).to be(true)

      finals = wait_for_event("finalized", unit_id: slow_unit, timeout: 20)
      expect(finals.size).to eq(1)
      expect(finals.first).to include("worker_id" => sibling, "outcome" => "passed", "reclaim_count" => 1)
      expect(events("reclaimed", unit_id: slow_unit).first).to include("previous_worker_id" => stopped,
                                                                       "worker_id" => sibling)
      expect(handles.fetch(stopped).alive?).to be(true)
      expect(handles.fetch(stopped).kill("CONT")).to be(true)

      expect(wait_all(handles, timeout: 30)).to eq("w1" => 0, "w2" => 0)
      stale = events("stale_rejected", unit_id: slow_unit)
      expect(stale.size).to eq(1)
      expect(stale.first).to include("worker_id" => stopped, "operation" => "finalize", "reclaim_count" => 0)
      expect(handles.fetch(stopped).stdout).to include("reservation for #{slow_unit} is stale; result discarded")
      expect(attempt_log.finalized_events(slow_unit).size).to eq(1)

      slow_ids = manifest.file_counts.fetch(slow_unit)
      stopped_examples = formatter_examples(out_path("#{stopped}.json"))
      sibling_examples = formatter_examples(out_path("#{sibling}.json"))
      expect(stopped_examples.keys.grep(/\A#{Regexp.escape(slow_unit)}/)).to be_empty
      expect(sibling_examples.keys.grep(/\A#{Regexp.escape(slow_unit)}/).size).to eq(slow_ids)
      expect(sibling_examples.values).to all(eq("passed"))
      expect((stopped_examples.keys + sibling_examples.keys).tally.values).to all(eq(1))
      expect(stopped_examples.size + sibling_examples.size).to eq(manifest.total_examples)
      expect_consistent_build
    end
  end

  describe "(c) initializer dies between taking the lease and publishing" do
    it "lets another worker initialize once the lease expires" do
      # The real window between SET NX and the init script is microseconds,
      # so the dead initializer is simulated by a lease nobody will release.
      leader_key = keys_for.leader
      redis.set(leader_key, "dead-initializer:nonce", ex: 3)
      lease_taken_at = monotonic
      handles = spawn_workers(2, fixture: "all-pass", args: ["--init-timeout", "20"])

      wait_until(timeout: 3, message: "workers to boot while the lease is held") do
        handles.values.all?(&:alive?) && redis.get(leader_key) == "dead-initializer:nonce"
      end
      expect(queue.status.present?).to be(false)

      wait_for_ready(timeout: 15)
      expect(monotonic - lease_taken_at).to be >= 2.9

      expect(wait_all(handles, timeout: 30)).to eq("w1" => 0, "w2" => 0)
      initializers = handles.select { |_wid, h| h.stdout.include?("initialized build #{build_id}") }.keys
      joiners = handles.select { |_wid, h| h.stdout.include?("joined build #{build_id}") }.keys
      expect(initializers.size).to eq(1)
      expect(joiners).to eq(handles.keys - initializers)
      expect(redis.get(leader_key)).to start_with("#{initializers.first}:")
      expect(redis.exists(keys_for.meta)).to eq(1)
      expect(queue.status).to have_attributes(state: "ready", tombstone: true)
      expect(manifest.total_units).to eq(3)
      expect(events("delivered").size).to eq(3)
      expect_consistent_build
    end
  end

  describe "(d) SIGKILL a worker mid-retry" do
    it "lets a sibling reclaim the priority-stream entry and the build completes" do
      handles = spawn_workers(2, fixture: "flaky-passes-on-attempt-3",
                                 args: ["--timeout", "2", "--max-requeues", "3", "--requeue-tolerance", "1"],
                                 env: state_env.merge("HOPPER_FIXTURE_RETRY_SLEEP" => "3"))
      victim = wait_until(timeout: 10, message: "a worker to hold the retried flaky unit") do
        unit_states.dig(flaky_unit, "retry_index").to_i >= 1 && holder_of(flaky_unit)
      end
      kill_and_reap(handles.fetch(victim))
      sibling = (handles.keys - [victim]).first

      reclaimed = wait_for_event("reclaimed", unit_id: flaky_unit, timeout: 10)
      expect(reclaimed.size).to eq(1)
      expect(reclaimed.first).to include("worker_id" => sibling, "previous_worker_id" => victim,
                                         "stream" => "units:priority", "retry_index" => 1, "reclaim_count" => 1,
                                         "ownership_generation" => 3)

      expect(handles.fetch(sibling).wait(timeout: 30).exitstatus).to eq(0)
      final = attempt_log.finalized_events(flaky_unit)
      expect(final.size).to eq(1)
      expect(final.first).to include("outcome" => "passed", "worker_id" => sibling, "reclaim_count" => 1)
      expect(unit_states.fetch(flaky_unit)).to include("reclaim_count" => 1, "entered_retry" => true)
      expect(unit_states.fetch(flaky_unit)["retry_index"]).to be >= 1

      report = run_report(args: ["--summary-out", summary_path])
      expect(report.exit_code).to eq(0), report.stdout
      expect(summary["flaky"]).to eq([flaky_unit])
      expect(summary["reclaim_counts"]).to eq(flaky_unit => 1)
      expect_consistent_build
    end
  end

  describe "(e) aborts-process: a unit that kills its worker every time" do
    let(:max_total_workers) { 5 }

    # Spawns a replacement for every worker killed by a signal, up to
    # max_total_workers in all, until the build completes.
    def supervise(handles, fixture:, args:)
      spawned = handles.size
      killed = []
      wait_until(timeout: 40, interval: 0.1, message: "the build to complete") do
        handles.to_a.each do |wid, handle|
          status = try_reap(handle)
          next unless status&.signaled? && !killed.include?(wid)

          killed << wid
          next unless spawned < max_total_workers

          spawned += 1
          handles["w#{spawned}"] = spawn_worker(fixture: fixture, worker_id: "w#{spawned}", args: args)
        end
        complete?
      end
      killed
    end

    it "finalizes the unit as reclaim_budget_exhausted after --max-reclaims reclaims and the build ends" do
      args = ["--timeout", "2", "--max-reclaims", "2"]
      handles = spawn_workers(3, fixture: "aborts-process", args: args)
      killed = supervise(handles, fixture: "aborts-process", args: args)

      expect(killed.size).to eq(3)
      expect(handles.size).to be <= max_total_workers
      killed.each { |wid| expect(handles.fetch(wid).termsig).to eq(sigkill) }
      survivors = handles.except(*killed)
      expect(wait_all(survivors, timeout: 30).values).to all(eq(0))

      reclaimed = events("reclaimed", unit_id: abort_unit)
      expect(reclaimed.size).to eq(2)
      expect(reclaimed.map { |e| e["reclaim_count"] }).to eq([1, 2])
      expect(reclaimed.map { |e| e["previous_worker_id"] }).to eq(killed.first(2))
      final = attempt_log.finalized_events(abort_unit)
      expect(final.size).to eq(1)
      expect(final.first).to include("outcome" => "failed", "reason" => "reclaim_budget_exhausted",
                                     "reclaim_count" => 2, "previous_worker_id" => killed.last)
      expect(unit_states.fetch(abort_unit)).to include("reclaim_count" => 2, "retry_index" => 0)

      report = run_report(args: ["--summary-out", summary_path])
      expect(report.exit_code).to eq(1), report.stdout
      expect(summary["failed"].map { |f| f.values_at("unit_id", "reason") })
        .to eq([[abort_unit, "reclaim_budget_exhausted"]])
      expect(summary["reclaim_counts"]).to eq(abort_unit => 2)
      expect_consistent_build
    end
  end

  describe "(f) hangs-forever with short --max-unit-duration and --timeout" do
    let(:args) { ["--max-unit-duration", "2", "--timeout", "2", "--max-reclaims", "1"] }
    let(:abort_line) { "Aborting worker: #{hang_unit} exceeded 2s" }

    it "records abandoned, a sibling reclaims, the hung worker exits 4 and report lists the unit as abandoned" do
      # Every worker that reclaims the unit hangs and aborts itself too, so a
      # third worker is needed to make the reclaim that exhausts the budget.
      handles = spawn_workers(3, fixture: "hangs-forever", args: args)
      first = wait_for_holder(hang_unit)
      abandoned = wait_for_event("abandoned", unit_id: hang_unit, timeout: 10)
      expect(abandoned.first).to include("worker_id" => first, "reclaim_count" => 0)
      expect(abandoned.first["elapsed_ms"]).to be >= 2000

      expect(handles.fetch(first).wait(timeout: 15).exitstatus).to eq(4)
      expect(handles.fetch(first).stderr).to include("[hopper #{first}] #{abort_line}")

      reclaimed = wait_for_event("reclaimed", unit_id: hang_unit, timeout: 10)
      expect(reclaimed.size).to eq(1)
      expect(reclaimed.first).to include("previous_worker_id" => first, "reclaim_count" => 1)
      second = reclaimed.first["worker_id"]
      expect(second).not_to eq(first)
      expect(handles.fetch(second).wait(timeout: 15).exitstatus).to eq(4)
      expect(handles.fetch(second).stderr).to include(abort_line)

      third = (handles.keys - [first, second]).first
      expect(handles.fetch(third).wait(timeout: 15).exitstatus).to eq(0)
      final = attempt_log.finalized_events(hang_unit)
      expect(final.size).to eq(1)
      expect(final.first).to include("outcome" => "failed", "reason" => "reclaim_budget_exhausted",
                                     "worker_id" => third, "previous_worker_id" => second, "reclaim_count" => 1)
      expect(events("abandoned", unit_id: hang_unit).map { |e| e["worker_id"] }).to eq([first, second])

      report = run_report(args: ["--summary-out", summary_path])
      expect(report.exit_code).to eq(1), report.stdout
      expect(report.stdout).to include("abandoned (exceeded --max-unit-duration): #{hang_unit}")
      expect(summary["abandoned"]).to eq([hang_unit])
      expect(summary["failed"].map { |f| f.values_at("unit_id", "reason") })
        .to eq([[hang_unit, "reclaim_budget_exhausted"]])
      expect_consistent_build
    end

    it "with one worker: the worker exits 4, report exits 3 on inactivity and names the abandoned unit" do
      worker = spawn_worker(fixture: "hangs-forever", worker_id: "w1", args: args)
      report = spawn_report(args: ["--inactive-timeout", "3", "--init-timeout", "15", "--summary-out", summary_path])
      wait_for_holder(hang_unit)

      expect(worker.wait(timeout: 15).exitstatus).to eq(4)
      expect(worker.stderr).to include("[hopper w1] #{abort_line}")
      abandoned = events("abandoned", unit_id: hang_unit)
      expect(abandoned.size).to eq(1)

      report.wait(timeout: 30)
      expect(report.exit_code).to eq(3), report.stdout
      expect(report.stdout).to include("incomplete: workers inactive for")
      expect(report.stdout).to include("never finalized: #{hang_unit} (last worker w1)")
      expect(report.stdout).to include("abandoned (exceeded --max-unit-duration): #{hang_unit}")
      expect(summary).to include("verdict" => "incomplete", "exit_code" => 3, "abandoned" => [hang_unit])
      expect(summary["never_finalized"]).to include("unit_id" => hang_unit, "last_worker_id" => "w1")
      expect(attempt_log.finalized_events(hang_unit)).to be_empty
      expect(HopperSpec::RedisHelper.ttls(redis, build_id).values).to all(be_positive)
    end
  end
end
