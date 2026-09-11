# frozen_string_literal: true

RSpec.describe RSpec::Hopper::Worker::Heartbeat do
  let(:clock) { HopperSpec::FakeClock.new(1_000.0) }
  let(:config) { RSpec::Hopper::WorkConfig.build(build_id: "b", worker_id: "w1", timeout: 30, max_unit_duration: 100) }
  let(:manifest) { RSpec::Hopper::Manifest.new(total_examples: 1, file_counts: { "./spec/a_spec.rb" => 1 }, file_args: []) }
  let(:queue) { HopperSpec::FakeQueue.new(clock: clock).tap { |q| q.seed_ready!(manifest) } }
  let(:reservation) { queue.reserve("w1") }
  let(:err) { StringIO.new }
  let(:aborted) { [] }

  def heartbeat(**opts)
    described_class.new(queue: queue, reservation: reservation, config: config, err: err, clock: clock,
                        aborter: ->(code) { aborted << code }, **opts)
  end

  it "uses min(timeout / 3, 30) as its interval" do
    expect(heartbeat.interval).to eq(10.0)
    long = config.with(timeout: 600)
    expect(described_class.new(queue: queue, reservation: reservation, config: long).interval).to eq(30.0)
  end

  it "renews the reservation once per interval" do
    hb = heartbeat.prime
    expect(hb.tick(1_000.0)).to eq(:idle)
    expect(hb.tick(1_009.9)).to eq(:idle)
    expect(hb.tick(1_010.0)).to eq(:renewed)
    expect(hb.tick(1_015.0)).to eq(:idle)
    expect(hb.tick(1_020.0)).to eq(:renewed)
    expect(queue.heartbeats.size).to eq(2)
    expect(hb.renewals).to eq(2)
    expect(hb).not_to be_stale
  end

  it "stops renewing once the reservation is stale" do
    hb = heartbeat.prime
    queue.simulate_reclaim(reservation.unit_id, by: "w2")
    expect(hb.tick(1_010.0)).to eq(:stale)
    expect(hb).to be_stale
    expect(queue.heartbeats).to be_empty
  end

  it "records abandoned once after max_unit_duration and aborts after a further timeout" do
    hb = heartbeat.prime
    hb.tick(1_010.0)
    expect(hb.tick(1_100.0)).to eq(:abandoned)
    expect(hb.tick(1_120.0)).to eq(:abandoned)
    expect(hb).to be_abandoned
    events = queue.events_of("abandoned")
    expect(events.size).to eq(1)
    expect(events.first).to include("unit_id" => "./spec/a_spec.rb", "elapsed_ms" => 100_000)
    expect(queue.heartbeats.size).to eq(1)
    expect(aborted).to be_empty

    expect(hb.tick(1_129.9)).to eq(:abandoned)
    expect(hb.tick(1_130.0)).to eq(:aborted)
    expect(aborted).to eq([RSpec::Hopper::ExitCode::ABORTED])
    expect(err.string).to eq("[hopper w1] Aborting worker: ./spec/a_spec.rb exceeded 100s\n")
  end

  it "returns :stopped after stop" do
    hb = heartbeat.prime
    hb.stop
    expect(hb.tick(1_010.0)).to eq(:stopped)
  end

  it "runs in a thread that renews on schedule and exits promptly on stop" do
    fast = config.with(timeout: 0.03)
    hb = described_class.new(queue: queue, reservation: reservation, config: fast, err: err,
                             aborter: ->(code) { aborted << code })
    hb.start
    expect(hb).to be_running
    Timeout.timeout(2) { sleep 0.005 until queue.heartbeats.size >= 2 }
    hb.stop
    expect(hb).not_to be_running
    expect(aborted).to be_empty
  end

  it "drives the thread with an injected clock through abandon and abort" do
    hb = heartbeat(sleeper: ->(seconds) { clock.advance(seconds) })
    hb.start
    Timeout.timeout(2) { sleep 0.005 while aborted.empty? }
    hb.stop
    expect(queue.events_of("abandoned").size).to eq(1)
    expect(aborted).to eq([4])
    expect(err.string).to include("Aborting worker: ./spec/a_spec.rb exceeded 100s")
  end
end
