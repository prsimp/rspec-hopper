# frozen_string_literal: true

# rubocop:disable Style/FormatStringToken -- "%{n}" is the documented placeholder syntax
# These specs really fork. The children run a tiny scripted worker class (no
# RSpec suite is loaded or run in them) that records what it observed to a
# file and exits with a scripted code, so the parent's precedence, formatter
# and signal handling are exercised end to end.
RSpec.describe RSpec::Hopper::Supervisor do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:state_dir) { Dir.mktmpdir("hopper-supervisor") }
  let(:config) do
    RSpec::Hopper::WorkConfig.build(build_id: "b1", worker_id: "w", redis_url: "redis://127.0.0.1:6399/1",
                                    processes: 2, rspec_args: %w[--tag fast],
                                    report_args: %w[--build b1 --redis redis://127.0.0.1:6399/1])
  end
  let(:script) { { "w" => 0, "w.1" => 0, "w.2" => 0 } }
  let(:after_fork_calls) { [] }

  # A worker double that survives fork: records its config and environment to
  # state_dir/<worker_id>, then exits with the scripted code, is killed, or
  # sleeps until signalled.
  let(:fake_worker) do
    dir = state_dir
    plan = script
    hook_calls = after_fork_calls
    Class.new do
      define_method(:initialize) do |config:, queue_factory:, out:, err:, suite: nil|
        @config = config
        @queue_factory = queue_factory
        @suite = suite
        @out = out
        @err = err
      end

      define_method(:run) do
        File.write(File.join(dir, @config.worker_id), JSON.generate(
                                                        "worker_id" => @config.worker_id,
                                                        "supervised" => @config.supervised,
                                                        "processes" => @config.processes,
                                                        "rspec_args" => @config.rspec_args,
                                                        "env_number" => ENV.fetch("TEST_ENV_NUMBER", "<unset>"),
                                                        "suite" => @suite.to_s,
                                                        "queue_factory" => @queue_factory.class.name,
                                                        "after_fork_calls" => hook_calls,
                                                        "pid" => Process.pid
                                                      ))
        case (action = plan.fetch(@config.worker_id))
        when :kill then Process.kill("KILL", Process.pid)
        when :sleep then sleep
        else action
        end
      end
    end
  end

  after do
    # Reap any child the supervisor started (only relevant when a spec fails).
    err.string.scan(/\(pid (\d+)/).flatten.map(&:to_i).each do |pid|
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    FileUtils.rm_rf(state_dir)
  end

  def supervisor(**opts)
    described_class.new(config: opts.delete(:config) || config, out: out, err: err, worker_class: fake_worker, **opts)
  end

  def recorded(worker_id)
    JSON.parse(File.read(File.join(state_dir, worker_id)))
  end

  describe "exit-code precedence without --report-on-exit" do
    {
      "0 and 0 -> 0" => [{ "w.1" => 0, "w.2" => 0 }, 0],
      "0 and 4 -> 4" => [{ "w.1" => 0, "w.2" => 4 }, 4],
      "4 and 2 -> 2" => [{ "w.1" => 4, "w.2" => 2 }, 2],
      "2 and 0 -> 2" => [{ "w.1" => 2, "w.2" => 0 }, 2],
      "an unexpected code counts as 2" => [{ "w.1" => 0, "w.2" => 1 }, 2],
      "a signal-killed child counts as 2" => [{ "w.1" => :kill, "w.2" => 4 }, 2]
    }.each do |name, (plan, expected)|
      it name do
        script.replace(plan)
        expect(supervisor.run).to eq(expected)
      end
    end

    it "reports how a signalled child died" do
      script.replace("w.1" => :kill, "w.2" => 0)
      supervisor.run
      expect(err.string).to match(/\[hopper w\] w\.1 \(pid \d+\) killed by SIGKILL/)
      expect(err.string).to match(/\[hopper w\] w\.2 \(pid \d+\) exited 0/)
    end
  end

  describe "with --report-on-exit" do
    let(:config) { super().with(report_on_exit: true) }
    let(:report_calls) { [] }
    let(:report_runner) do
      calls = report_calls
      ->(args, out:, err:) { calls << [args, out, err]; 1 } # rubocop:disable Style/Semicolon
    end

    it "returns the report's exit code and treats a child 4 as diagnostic" do
      script.replace("w.1" => 0, "w.2" => 4)
      expect(supervisor(report_runner: report_runner).run).to eq(1)
      expect(report_calls).to eq([[%w[--build b1 --redis redis://127.0.0.1:6399/1], out, err]])
      expect(err.string).to include("a child aborted a hung unit (exit 4)")
    end

    it "returns the report's exit code when every child passed" do
      report = ->(_args, out:, err:) { 0 } # rubocop:disable Lint/UnusedBlockArgument
      expect(supervisor(report_runner: report).run).to eq(0)
    end

    it "returns 2 without running the report if any child exited 2" do
      script.replace("w.1" => 2, "w.2" => 0)
      expect(supervisor(report_runner: report_runner).run).to eq(2)
      expect(report_calls).to be_empty
    end
  end

  describe "per-process boot" do
    it "gives each child its own worker id, TEST_ENV_NUMBER, supervised config and no suite" do
      expect(supervisor.run).to eq(0)
      first = recorded("w.1")
      second = recorded("w.2")
      expect(first).to include("worker_id" => "w.1", "env_number" => "", "supervised" => true, "processes" => 1,
                               "suite" => "", "queue_factory" => "Proc")
      expect(second).to include("worker_id" => "w.2", "env_number" => "2", "supervised" => true)
      expect(first["pid"]).not_to eq(second["pid"])
      expect([first["pid"], second["pid"]]).not_to include(Process.pid)
    end

    it "logs one start and one exit line per child" do
      supervisor.run
      lines = err.string.lines
      expect(lines.grep(/\[hopper w\] started w\.1 \(pid \d+, TEST_ENV_NUMBER=""\)/).size).to eq(1)
      expect(lines.grep(/\[hopper w\] started w\.2 \(pid \d+, TEST_ENV_NUMBER="2"\)/).size).to eq(1)
      expect(lines.grep(/\[hopper w\] w\.\d \(pid \d+\) exited 0/).size).to eq(2)
    end

    it "strips formatter options in the parent and re-applies them per child with %{n} substituted" do
      args = %w[--tag fast --format json --out tmp/%{n}/out.json -fdoc --order rand -- spec/a spec/b]
      expect(supervisor(config: config.with(rspec_args: args)).run).to eq(0)
      expect(recorded("w.1")["rspec_args"])
        .to eq(%w[--format json --out tmp//out.json --format doc --out tmp/rspec-hopper/w-1-doc.txt
                  --tag fast --order rand -- spec/a spec/b])
      expect(recorded("w.2")["rspec_args"])
        .to eq(%w[--format json --out tmp/2/out.json --format doc --out tmp/rspec-hopper/w-2-doc.txt
                  --tag fast --order rand -- spec/a spec/b])
    end

    it "gives a child with no formatter options of its own a file, so nothing prints to the console" do
      expect(supervisor.run).to eq(0)
      expect(recorded("w.1")["rspec_args"].first(4))
        .to eq(%w[--format progress --out tmp/rspec-hopper/w-1-progress.txt])
      expect(recorded("w.2")["rspec_args"].first(4))
        .to eq(%w[--format progress --out tmp/rspec-hopper/w-2-progress.txt])
    end

    it "says where the generated output went" do
      supervisor.run
      expect(err.string).to include("[hopper w] formatter output: tmp/rspec-hopper/")
      expect(err.string).to include("verdict comes from `rspec-hopper report`")
    end

    it "stays quiet about generated output when every formatter already has an --out" do
      args = %w[--format json --out tmp/%{n}/out.json]
      supervisor(config: config.with(rspec_args: args)).run
      expect(err.string).not_to include("formatter output:")
    end

    it "uses the parent's queue factory builder for each child" do
      factories = []
      builder = ->(child_config) { factories << child_config.worker_id; -> { :queue } } # rubocop:disable Style/Semicolon
      supervisor(queue_factory_for: builder).run
      expect(factories).to be_empty # only children build queues
      expect(recorded("w.1")["queue_factory"]).to eq("Proc")
    end
  end

  describe "#child_config" do
    it "derives the child's config without forking" do
      child = supervisor.child_config(2, %w[spec/a], [%w[--out r-%{n}.xml]])
      expect(child.to_h).to include(worker_id: "w.2", supervised: true, processes: 1, build_id: "b1",
                                    rspec_args: %w[--format progress --out r-2.xml spec/a])
      expect(described_class.env_number(1)).to eq("")
      expect(described_class.env_number(3)).to eq("3")
    end
  end

  describe "shared boot" do
    let(:config) { super().with(boot: :shared, rspec_args: %w[--tag fast --format json]) }
    let(:before_fork_calls) { [] }
    let(:loader_calls) { [] }
    let(:suite_loader) do
      before = before_fork_calls
      hook_calls = after_fork_calls
      calls = loader_calls
      lambda do |args, config:, out:, err:|
        calls << { args: args, worker_id: config.worker_id, env_number: ENV.fetch("TEST_ENV_NUMBER", "<unset>"),
                   out: out, err: err }
        RSpec::Hopper.before_fork { before << Process.pid }
        RSpec::Hopper.after_fork { |n| hook_calls << [n, Process.pid] }
        :the_suite
      end
    end

    around do |example|
      previous = ENV.fetch("TEST_ENV_NUMBER", nil)
      ENV["TEST_ENV_NUMBER"] = "9"
      example.run
    ensure
      previous.nil? ? ENV.delete("TEST_ENV_NUMBER") : ENV["TEST_ENV_NUMBER"] = previous
    end

    it "loads the suite once in the parent with TEST_ENV_NUMBER unset and formatter args stripped" do
      expect(supervisor(suite_loader: suite_loader).run).to eq(0)
      expect(loader_calls).to eq([{ args: %w[--tag fast], worker_id: "w", env_number: "<unset>", out: out, err: err }])
    end

    it "runs before_fork once in the parent and after_fork in each child with its TEST_ENV_NUMBER" do
      supervisor(suite_loader: suite_loader).run
      expect(before_fork_calls).to eq([Process.pid])
      expect(after_fork_calls).to be_empty
      first = recorded("w.1")
      second = recorded("w.2")
      expect(first["after_fork_calls"]).to eq([["", first["pid"]]])
      expect(second["after_fork_calls"]).to eq([["2", second["pid"]]])
      expect(first).to include("env_number" => "", "suite" => "the_suite",
                               "rspec_args" => %w[--format json --out tmp/rspec-hopper/w-1-json.json --tag fast])
      expect(second).to include("env_number" => "2", "suite" => "the_suite")
    end

    it "refuses to fork without an after_fork hook and says why" do
      loader = ->(_args, config:, out:, err:) { :suite } # rubocop:disable Lint/UnusedBlockArgument
      forker = ->(&_block) { raise "must not fork" }
      expect(supervisor(suite_loader: loader, fork: forker).run).to eq(2)
      expect(err.string).to include("--boot shared needs at least one RSpec::Hopper.after_fork hook")
        .and include("use --boot per-process")
    end

    it "maps a boot failure in the parent to its exit code" do
      loader = ->(_args, config:, out:, err:) { raise RSpec::Hopper::UnsupportedOption, "--fail-fast" } # rubocop:disable Lint/UnusedBlockArgument
      expect(supervisor(suite_loader: loader).run).to eq(2)
      expect(err.string).to include("[hopper w] --fail-fast")
    end
  end

  describe "signals" do
    it "forwards INT to every live child and reports them as killed" do
      script.replace("w.1" => :sleep, "w.2" => :sleep)
      runner = Thread.new { supervisor.run }
      Timeout.timeout(10) { sleep 0.02 until %w[w.1 w.2].all? { |w| File.exist?(File.join(state_dir, w)) } }
      Process.kill("INT", Process.pid)
      expect(runner.join(10)).not_to be_nil, "supervisor did not return after INT"
      expect(runner.value).to eq(2)
      expect(err.string.scan("killed by SIGINT").size).to eq(2)
    end

    it "restores the previous INT and TERM handlers" do
      before = %w[INT TERM].map { |s| trap(s, "DEFAULT") }
      begin
        supervisor.run
        expect(trap("INT", "DEFAULT")).to eq("DEFAULT")
        expect(trap("TERM", "DEFAULT")).to eq("DEFAULT")
      ensure
        %w[INT TERM].zip(before).each { |s, h| trap(s, h) }
      end
    end
  end

  describe "--processes 1" do
    it "runs one worker inline with no fork" do
      forker = ->(&_block) { raise "must not fork" }
      inline = supervisor(config: config.with(processes: 1), fork: forker, queue_factory_for: ->(_c) { -> { :q } })
      expect(inline.run).to eq(0)
      expect(recorded("w")).to include("worker_id" => "w", "supervised" => false, "pid" => Process.pid)
      expect(err.string).to be_empty
    end
  end

  describe "without fork" do
    it "refuses --processes N above 1 with exit 2" do
      expect(supervisor(fork_available: false).run).to eq(2)
      expect(err.string).to include("[hopper w] --processes 2 needs fork")
    end
  end
end
# rubocop:enable Style/FormatStringToken
