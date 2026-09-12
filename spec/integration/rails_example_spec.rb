# frozen_string_literal: true

# Drives examples/rails-app, the smallest Rails application with a database,
# through real worker processes: shared boot forking three children onto
# their own SQLite databases, transactional examples, before(:all) records,
# a request spec, and a flaky example retried inside Rails, in both unit
# modes. Skipped unless the app's bundle is installed.
RSpec.describe "rspec-hopper against the Rails example app", :integration, :rails, :redis do
  let(:app) { HopperSpec::RailsExample }
  let(:example_ids) do
    %w[./spec/models/comment_spec.rb[1:1] ./spec/models/context_hooks_spec.rb[1:1]
       ./spec/models/context_hooks_spec.rb[1:2] ./spec/models/flaky_spec.rb[1:1]
       ./spec/models/isolation_spec.rb[1:1] ./spec/models/isolation_spec.rb[1:2]
       ./spec/models/post_spec.rb[1:1] ./spec/models/post_spec.rb[1:2] ./spec/models/post_spec.rb[1:3]
       ./spec/requests/posts_spec.rb[1:1] ./spec/requests/posts_spec.rb[1:2] ./spec/requests/posts_spec.rb[1:3]]
  end
  let(:retry_args) { ["--max-requeues", "1", "--requeue-tolerance", "1"] }

  before { app.clean! }
  after { app.clean! }

  def formatter_union(names)
    names.map { |name| formatter_examples(out_path(name)) }.reduce({}) do |all, one|
      expect(all.keys & one.keys).to be_empty
      all.merge(one)
    end
  end

  shared_examples "a shared-boot build" do |unit_type, flaky_unit|
    it "boots once, forks three children onto their own databases and passes after one retry" do
      node = app.spawn_work(build_id: build_id, worker_id: "node", redis_url: redis_url,
                            args: ["--processes", "3", "--boot", "shared", "--report-on-exit", "--unit", unit_type,
                                   *retry_args, "--format", "json", "--out", out_path("node-%{n}.json"), # rubocop:disable Style/FormatStringToken
                                   "--order", "defined"])
      node.wait(timeout: 120)
      expect(node.exit_code).to eq(0), "#{node.stdout}\n#{node.stderr}"
      expect(node.stdout).to include("rspec-hopper report: build #{build_id}: passed")

      expect(manifest).to have_attributes(unit_type: unit_type, total_examples: app::EXAMPLE_COUNT)
      expect(workers.keys).to contain_exactly("node.1", "node.2", "node.3")
      expect(app.databases).to eq(%w[test.sqlite3 test2.sqlite3 test3.sqlite3])

      expect(events("requeued").map { |e| e["unit_id"] }).to eq([flaky_unit])
      expect(attempt_log.flaky).to eq([flaky_unit])
      expect(attempt_log.failed).to be_empty

      seen = formatter_union(%w[node-.json node-2.json node-3.json])
      expect(seen.keys).to match_array(example_ids)
      expect(seen.values.uniq).to eq(["passed"])
      expect_consistent_build
    end
  end

  describe "file units" do
    it_behaves_like "a shared-boot build", "file", "./spec/models/flaky_spec.rb"
  end

  describe "example units" do
    it_behaves_like "a shared-boot build", "example", "./spec/models/flaky_spec.rb[1:1]"
  end

  it "runs a single per-process worker through rails_helper and reports example ids for failures" do
    worker = app.spawn_work(build_id: build_id, worker_id: "solo", redis_url: redis_url,
                            args: ["--unit", "example", "--order", "defined"])
    worker.wait(timeout: 120)
    expect(worker.exit_code).to eq(0), worker.stderr
    expect(app.databases).to eq(%w[test.sqlite3])

    report = run_report(args: ["--summary-out", summary_path, "--failed-out", out_path("failed.txt")])
    expect(report.exit_code).to eq(1), report.stdout
    expect(summary).to include("verdict" => "failed", "unit_type" => "example",
                               "total_units" => app::EXAMPLE_COUNT, "flaky" => [])
    expect(File.read(out_path("failed.txt"))).to eq("./spec/models/flaky_spec.rb[1:1]\n")
    expect_consistent_build
  end
end
