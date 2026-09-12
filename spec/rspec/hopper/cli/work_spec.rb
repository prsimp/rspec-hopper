# frozen_string_literal: true

RSpec.describe RSpec::Hopper::CLI::Work do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:required) { %w[--build b1 --worker w1 --redis redis://127.0.0.1:6399/1] }

  def parse(*argv, env: {})
    described_class.parse(argv, env: env)
  end

  describe ".parse" do
    it "builds a frozen WorkConfig with the product-spec defaults" do
      config = parse(*required)
      expect(config).to be_frozen
      expect(config.to_h).to include(
        build_id: "b1", worker_id: "w1", redis_url: "redis://127.0.0.1:6399/1",
        timeout: 180, max_unit_duration: 900, max_requeues: 0, requeue_tolerance: 0.0, max_reclaims: 3,
        processes: 1, boot: :per_process, report_on_exit: false,
        ttl: 14_400, tombstone_ttl: 604_800, init_timeout: 300, revision: nil,
        rspec_args: [], supervised: false
      )
      expect(config.report_args).to eq(%w[--build b1 --redis redis://127.0.0.1:6399/1])
    end

    it "parses every gem flag" do
      config = parse(*required, "--timeout", "2.5", "--max-unit-duration", "30", "--max-requeues", "5",
                     "--requeue-tolerance", "0.25", "--max-reclaims", "1", "--processes", "3", "--boot", "shared",
                     "--report-on-exit", "--ttl", "60", "--tombstone-ttl", "120", "--init-timeout", "9",
                     "--revision", "abc123")
      expect(config.to_h).to include(
        timeout: 2.5, max_unit_duration: 30, max_requeues: 5, requeue_tolerance: 0.25, max_reclaims: 1,
        processes: 3, boot: :shared, report_on_exit: true, ttl: 60, tombstone_ttl: 120, init_timeout: 9,
        revision: "abc123"
      )
    end

    it "passes unrecognised options, positionals and everything after -- to RSpec in original order" do
      config = parse("--tag", "~slow", "--build", "b1", "spec/first", "--format", "json", "--out", "out.json",
                     "--worker", "w1", "-fdoc", "--seed", "7", "--redis", "r://x", "--", "spec/models", "spec/lib",
                     "--processes")
      expect(config.rspec_args).to eq(%w[--tag ~slow spec/first --format json --out out.json -fdoc --seed 7
                                         -- spec/models spec/lib --processes])
      expect(config.rspec_args).to be_frozen
      expect(config.processes).to eq(1)
    end

    it "passes through unknown options given in --name=value form" do
      config = parse(*required, "--example-matches=foo", "--order=rand")
      expect(config.rspec_args).to eq(%w[--example-matches=foo --order=rand])
    end

    it "raises HelpRequested with the option summary on --help" do
      expect { parse("--help") }.to raise_error(RSpec::Hopper::CLI::HelpRequested) { |e|
        expect(e.text).to include("Usage: rspec-hopper work").and include("--requeue-tolerance")
      }
    end

    describe "identity fallbacks" do
      it "uses HOPPER_BUILD_ID, HOPPER_WORKER_ID and HOPPER_REDIS_URL" do
        env = { "HOPPER_BUILD_ID" => "eb", "HOPPER_WORKER_ID" => "ew", "HOPPER_REDIS_URL" => "redis://env/1" }
        config = parse(env: env)
        expect([config.build_id, config.worker_id, config.redis_url]).to eq(["eb", "ew", "redis://env/1"])
      end

      it "prefers flags over the environment" do
        env = { "HOPPER_BUILD_ID" => "eb", "HOPPER_WORKER_ID" => "ew", "HOPPER_REDIS_URL" => "redis://env/1" }
        config = parse(*required, env: env)
        expect([config.build_id, config.worker_id, config.redis_url]).to eq(["b1", "w1", "redis://127.0.0.1:6399/1"])
      end

      it "falls back to REDIS_URL after HOPPER_REDIS_URL" do
        expect(parse("--build", "b", env: { "REDIS_URL" => "redis://plain/0" }).redis_url).to eq("redis://plain/0")
        env = { "REDIS_URL" => "redis://plain/0", "HOPPER_REDIS_URL" => "redis://hopper/0" }
        expect(parse("--build", "b", env: env).redis_url).to eq("redis://hopper/0")
      end

      it "infers build and worker ids from CI variables" do
        env = { "CIRCLECI" => "true", "CIRCLE_WORKFLOW_ID" => "wf", "CIRCLE_NODE_INDEX" => "2", "REDIS_URL" => "r://x" }
        config = parse(env: env)
        expect([config.build_id, config.worker_id]).to eq(%w[wf 2])
      end

      it "prefers HOPPER_* variables over CI inference" do
        env = { "CIRCLECI" => "true", "CIRCLE_WORKFLOW_ID" => "wf", "CIRCLE_NODE_INDEX" => "2",
                "HOPPER_BUILD_ID" => "hb", "HOPPER_WORKER_ID" => "hw", "REDIS_URL" => "r://x" }
        config = parse(env: env)
        expect([config.build_id, config.worker_id]).to eq(%w[hb hw])
      end

      it "defaults the worker id to hostname-pid when nothing names it" do
        config = parse("--build", "b", "--redis", "r://x")
        expect(config.worker_id).to eq("#{Socket.gethostname}-#{Process.pid}")
      end

      it "requires a build id, naming the flag" do
        expect { parse("--redis", "r://x") }.to raise_error(RSpec::Hopper::UsageError, /--build is required/)
      end

      it "requires a redis url, naming the flag" do
        expect { parse("--build", "b") }.to raise_error(RSpec::Hopper::UsageError, /--redis is required/)
      end
    end

    describe "validation" do
      {
        %w[--processes 0] => /--processes must be at least 1/,
        %w[--processes two] => /invalid argument: --processes two/,
        %w[--requeue-tolerance 1.5] => /--requeue-tolerance must be between 0 and 1/,
        %w[--requeue-tolerance -0.1] => /--requeue-tolerance must be between 0 and 1/,
        %w[--boot sideways] => /invalid argument: --boot sideways/,
        %w[--timeout 0] => /--timeout must be positive/,
        %w[--max-unit-duration -1] => /--max-unit-duration must be positive/,
        %w[--ttl 0] => /--ttl must be positive/,
        %w[--tombstone-ttl 0] => /--tombstone-ttl must be positive/,
        %w[--init-timeout 0] => /--init-timeout must be positive/,
        %w[--max-requeues -1] => /--max-requeues must not be negative/,
        %w[--max-reclaims -2] => /--max-reclaims must not be negative/,
        %w[--build] => /missing argument: --build/
      }.each do |args, message|
        it "rejects #{args.join(" ")}" do
          expect { parse(*required, *args) }.to raise_error(RSpec::Hopper::UsageError, message)
        end
      end

      it "accepts the boundary values" do
        config = parse(*required, "--requeue-tolerance", "1", "--processes", "1", "--max-requeues", "0")
        expect(config.requeue_tolerance).to eq(1.0)
      end
    end
  end

  describe ".run" do
    let(:worker) { double("worker", run: 0) } # rubocop:disable RSpec/VerifiedDoubles
    let(:worker_class) { double("Worker", new: worker) } # rubocop:disable RSpec/VerifiedDoubles
    let(:supervisor) { instance_double(RSpec::Hopper::Supervisor, run: 4) }
    let(:supervisor_class) { class_double(RSpec::Hopper::Supervisor, new: supervisor) }

    def run(*argv, env: {})
      described_class.run(argv, out: out, err: err, env: env, worker_class: worker_class,
                                supervisor_class: supervisor_class)
    end

    it "runs one worker inline for --processes 1 and returns its exit code" do
      allow(worker).to receive(:run).and_return(4)
      expect(run(*required)).to eq(4)
      expect(worker_class).to have_received(:new) do |**kwargs|
        expect(kwargs.keys).to contain_exactly(:config, :queue_factory, :out, :err)
        expect(kwargs[:config].build_id).to eq("b1")
        expect(kwargs[:queue_factory]).to respond_to(:call)
        expect(kwargs.values_at(:out, :err)).to eq([out, err])
      end
      expect(supervisor_class).not_to have_received(:new)
    end

    it "does not open Redis before the worker asks for its queue" do
      allow(Redis).to receive(:new)
      run(*required)
      expect(Redis).not_to have_received(:new)
    end

    it "hands --processes N to the supervisor with the worker class" do
      expect(run(*required, "--processes", "2")).to eq(4)
      expect(supervisor_class).to have_received(:new)
        .with(config: an_object_having_attributes(processes: 2), out: out, err: err, worker_class: worker_class)
      expect(worker_class).not_to have_received(:new)
    end

    it "prints a usage error and returns 2" do
      expect(run("--redis", "r://x")).to eq(2)
      expect(err.string).to include("rspec-hopper work: --build is required").and include("--help")
    end

    it "prints help and returns 0" do
      expect(run("--help")).to eq(0)
      expect(out.string).to include("Usage: rspec-hopper work")
    end

    it "wraps Redis connection errors into a message and exit 2" do
      allow(worker).to receive(:run).and_raise(Redis::CannotConnectError, "connection refused")
      expect(run(*required)).to eq(2)
      expect(err.string).to include("Redis unreachable at redis://127.0.0.1:6399/1: connection refused")
    end

    it "maps infrastructure errors to their exit code with a message" do
      allow(worker).to receive(:run).and_raise(RSpec::Hopper::UnsupportedOption, "--fail-fast is not supported")
      expect(run(*required)).to eq(2)
      expect(err.string).to eq("rspec-hopper work: --fail-fast is not supported\n")
    end
  end

  describe ".queue_factory" do
    it "builds a RedisStreams queue from the config only when called" do
      config = parse(*required, "--ttl", "5", "--tombstone-ttl", "6", "--timeout", "7", "--max-requeues", "8",
                     "--requeue-tolerance", "0.5", "--max-reclaims", "9")
      redis = instance_double(Redis)
      allow(Redis).to receive(:new).with(url: "redis://127.0.0.1:6399/1").and_return(redis)
      queue_class = class_double(RSpec::Hopper::Queue::RedisStreams, new: :queue)
      stub_const("RSpec::Hopper::Queue::RedisStreams", queue_class)

      factory = described_class.queue_factory(config)
      expect(Redis).not_to have_received(:new)
      expect(factory.call).to eq(:queue)
      expect(queue_class).to have_received(:new).with(
        redis: redis, build_id: "b1", ttl: 5, tombstone_ttl: 6, timeout: 7, max_requeues: 8,
        requeue_tolerance: 0.5, max_reclaims: 9
      )
    end
  end
end
