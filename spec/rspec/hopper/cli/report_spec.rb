# frozen_string_literal: true

RSpec.describe RSpec::Hopper::CLI::Report do
  let(:env) { {} }
  let(:required) { %w[--build b1 --redis redis://localhost:6399/1] }

  describe ".parse" do
    it "returns a ReportConfig with the documented defaults" do
      config = described_class.parse(required, env: env)

      expect(config).to be_a(RSpec::Hopper::ReportConfig)
      expect(config).to be_frozen
      expect(config.to_h).to eq(
        build_id: "b1", redis_url: "redis://localhost:6399/1", timeout: 1080, init_timeout: 300,
        inactive_timeout: 300, summary_out: nil, failed_out: nil, allow_empty: false, min_examples: 0
      )
    end

    it "parses every flag" do
      config = described_class.parse(
        required + %w[--timeout 30 --init-timeout 5 --inactive-timeout 7.5 --summary-out s.json --failed-out f.txt
                      --allow-empty], env: env
      )

      expect(config.to_h).to include(timeout: 30.0, init_timeout: 5.0, inactive_timeout: 7.5, summary_out: "s.json",
                                     failed_out: "f.txt", allow_empty: true, min_examples: 0)
    end

    it "accepts --min-examples with the default --fail-on-empty" do
      config = described_class.parse(required + %w[--fail-on-empty --min-examples 12], env: env)
      expect(config.allow_empty).to be(false)
      expect(config.min_examples).to eq(12)
    end

    it "lets --fail-on-empty override an earlier --allow-empty" do
      config = described_class.parse(required + %w[--allow-empty --fail-on-empty], env: env)
      expect(config.allow_empty).to be(false)
    end

    it "rejects --allow-empty with a positive --min-examples" do
      expect { described_class.parse(required + %w[--allow-empty --min-examples 1], env: env) }
        .to raise_error(RSpec::Hopper::UsageError, /--allow-empty cannot be combined/)
    end

    it "allows --allow-empty with --min-examples 0" do
      expect(described_class.parse(required + %w[--allow-empty --min-examples 0], env: env).allow_empty).to be(true)
    end

    it "falls back to HOPPER_BUILD_ID and HOPPER_REDIS_URL" do
      env.merge!("HOPPER_BUILD_ID" => "env-build", "HOPPER_REDIS_URL" => "redis://env/0",
                 "REDIS_URL" => "redis://other/0")
      config = described_class.parse([], env: env)
      expect(config.build_id).to eq("env-build")
      expect(config.redis_url).to eq("redis://env/0")
    end

    it "falls back to REDIS_URL after HOPPER_REDIS_URL" do
      env.merge!("HOPPER_BUILD_ID" => "env-build", "REDIS_URL" => "redis://other/0")
      expect(described_class.parse([], env: env).redis_url).to eq("redis://other/0")
    end

    it "prefers flags over the environment" do
      env.merge!("HOPPER_BUILD_ID" => "env-build", "REDIS_URL" => "redis://other/0")
      config = described_class.parse(required, env: env)
      expect(config.build_id).to eq("b1")
      expect(config.redis_url).to eq("redis://localhost:6399/1")
    end

    it "raises UsageError when the build id is missing" do
      expect { described_class.parse(%w[--redis redis://x], env: env) }
        .to raise_error(RSpec::Hopper::UsageError, /--build ID is required/)
    end

    it "raises UsageError when the redis url is missing" do
      expect { described_class.parse(%w[--build b], env: env) }
        .to raise_error(RSpec::Hopper::UsageError, /--redis URL is required/)
    end

    it "raises UsageError for unknown options, bad numbers, and stray arguments" do
      expect { described_class.parse(required + %w[--bogus], env: env) }
        .to raise_error(RSpec::Hopper::UsageError, /invalid option: --bogus/)
      expect { described_class.parse(required + %w[--timeout soon], env: env) }
        .to raise_error(RSpec::Hopper::UsageError, /invalid argument: --timeout soon/)
      expect { described_class.parse(required + %w[--min-examples -1], env: env) }
        .to raise_error(RSpec::Hopper::UsageError, /--min-examples must not be negative/)
      expect { described_class.parse(required + %w[spec/foo_spec.rb], env: env) }
        .to raise_error(RSpec::Hopper::UsageError, /unexpected argument/)
    end

    it "raises HelpRequested for -h" do
      expect { described_class.parse(%w[-h], env: env) }.to raise_error(described_class::HelpRequested)
    end
  end

  describe ".usage" do
    it "documents every flag" do
      usage = described_class.usage
      %w[--build --redis --timeout --init-timeout --inactive-timeout --summary-out --failed-out --fail-on-empty
         --allow-empty --min-examples --help].each { |flag| expect(usage).to include(flag) }
    end
  end

  describe ".run" do
    let(:out) { StringIO.new }
    let(:err) { StringIO.new }
    let(:redis) { instance_double(Redis, close: nil) }
    let(:queue) { Object.new }
    let(:report) { instance_double(RSpec::Hopper::Report) }
    let(:adapter) { class_double(RSpec::Hopper::Queue).as_stubbed_const }

    before do
      stub_const("RSpec::Hopper::Queue::RedisStreams", Class.new)
      allow(Redis).to receive(:new).and_return(redis)
      allow(RSpec::Hopper::Queue::RedisStreams).to receive(:new).and_return(queue)
      allow(RSpec::Hopper::Report).to receive(:new).and_return(report)
    end

    it "wires Redis, the queue adapter and Report from the parsed config and returns Report's exit code" do
      allow(report).to receive(:run).and_return(1)

      code = described_class.run(required + %w[--timeout 9], out: out, err: err, env: env)

      expect(code).to eq(1)
      expect(Redis).to have_received(:new).with(url: "redis://localhost:6399/1")
      expect(RSpec::Hopper::Queue::RedisStreams).to have_received(:new).with(redis: redis, build_id: "b1")
      expect(RSpec::Hopper::Report).to have_received(:new)
        .with(config: an_object_having_attributes(build_id: "b1", timeout: 9.0), queue: queue)
      expect(report).to have_received(:run).with(out: out)
      expect(redis).to have_received(:close)
    end

    it "prints usage to err and returns 2 on a usage error" do
      code = described_class.run(%w[--build only], out: out, err: err, env: env)

      expect(code).to eq(2)
      expect(err.string).to include("--redis URL is required")
      expect(err.string).to include("Usage: rspec-hopper report")
      expect(out.string).to be_empty
      expect(RSpec::Hopper::Report).not_to have_received(:new)
    end

    it "prints usage to out and returns 0 for --help" do
      code = described_class.run(%w[--help], out: out, err: err, env: env)

      expect(code).to eq(0)
      expect(out.string).to include("Usage: rspec-hopper report")
      expect(err.string).to be_empty
    end

    it "prints the message and returns 2 on an infrastructure error" do
      allow(report).to receive(:run).and_raise(RSpec::Hopper::RedisUnreachable, "redis down")

      code = described_class.run(required, out: out, err: err, env: env)

      expect(code).to eq(2)
      expect(err.string).to include("rspec-hopper report: redis down")
      expect(redis).to have_received(:close)
    end
  end
end
