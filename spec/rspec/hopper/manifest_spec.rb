# frozen_string_literal: true

RSpec.describe RSpec::Hopper::Manifest do
  let(:file_counts) { { "./spec/a_spec.rb" => 3, "./spec/b_spec.rb" => 2 } }
  let(:manifest) do
    described_class.new(
      total_units: 2, total_examples: 5, file_counts: file_counts, file_args: %w[spec/a_spec.rb spec/b_spec.rb],
      fingerprint: "abc123", seed: 4242, ready_at: 1_700_000_000_000, revision: "deadbeef", load_errors: []
    )
  end

  describe ".new" do
    it "derives unit_ids from file_counts in order" do
      expect(manifest.unit_ids).to eq(["./spec/a_spec.rb", "./spec/b_spec.rb"])
    end

    it "defaults total_units to file_counts.size" do
      m = described_class.new(total_examples: 5, file_counts: file_counts, file_args: [], fingerprint: "f", seed: 1)
      expect(m.total_units).to eq(2)
      expect(m.ready_at).to be_nil
      expect(m.revision).to be_nil
      expect(m.load_errors).to eq([])
    end

    it "rejects total_units that disagrees with file_counts" do
      expect do
        described_class.new(total_units: 3, total_examples: 5, file_counts: file_counts, file_args: [],
                            fingerprint: "f", seed: 1)
      end.to raise_error(ArgumentError, /total_units \(3\) does not match file_counts.size \(2\)/)
    end

    it "coerces numeric strings and freezes nested collections" do
      m = described_class.new(total_units: "2", total_examples: "5", file_counts: { "./a" => "1", "./b" => "4" },
                              file_args: %w[a], fingerprint: "f", seed: "7", ready_at: "12")
      expect([m.total_units, m.total_examples, m.seed, m.ready_at]).to eq([2, 5, 7, 12])
      expect(m.file_counts).to eq("./a" => 1, "./b" => 4)
      expect(m.file_counts).to be_frozen
      expect(m.file_args).to be_frozen
      expect(m.load_errors).to be_frozen
    end

    it "is frozen" do
      expect(manifest).to be_frozen
    end
  end

  describe "#to_meta" do
    it "returns String => String pairs with nested fields JSON-encoded" do
      meta = manifest.to_meta
      expect(meta).to eq(
        "total_units" => "2",
        "total_examples" => "5",
        "file_counts" => '{"./spec/a_spec.rb":3,"./spec/b_spec.rb":2}',
        "file_args" => '["spec/a_spec.rb","spec/b_spec.rb"]',
        "load_errors" => "[]",
        "fingerprint" => "abc123",
        "seed" => "4242",
        "ready_at" => "1700000000000",
        "revision" => "deadbeef"
      )
      expect(meta.keys).to all(be_a(String))
      expect(meta.values).to all(be_a(String))
    end

    it "omits revision and ready_at when nil" do
      m = described_class.new(total_examples: 5, file_counts: file_counts, file_args: [], fingerprint: "f", seed: 1)
      expect(m.to_meta).not_to have_key("revision")
      expect(m.to_meta).not_to have_key("ready_at")
    end
  end

  describe "fingerprint digests" do
    let(:digests) do
      { "file_args" => "0123456789abcdef", "example_ids" => "fedcba9876543210", "example_ids_count" => 5 }
    end
    let(:with_digests) { described_class.new(**manifest.to_h, fingerprint_digests: digests) }

    it "JSON-encodes them into meta and reads them back" do
      expect(with_digests.to_meta.fetch("fingerprint_digests")).to eq(JSON.generate(digests))
      expect(described_class.from_meta(with_digests.to_meta)).to eq(with_digests)
    end

    it "is absent from meta and nil when the initializer recorded none" do
      expect(manifest.to_meta).not_to have_key("fingerprint_digests")
      expect(described_class.from_meta(manifest.to_meta).fingerprint_digests).to be_nil
    end

    it "treats an unparseable or non-object recording as absent" do
      ["not json", "[1,2]", ""].each do |value|
        meta = manifest.to_meta.merge("fingerprint_digests" => value)
        expect(described_class.from_meta(meta).fingerprint_digests).to be_nil
      end
    end
  end

  describe ".from_meta" do
    it "round-trips through to_meta" do
      expect(described_class.from_meta(manifest.to_meta)).to eq(manifest)
    end

    it "tolerates the runtime fields HGETALL returns alongside the manifest" do
      meta = manifest.to_meta.merge(
        "state" => "ready", "finalized_count" => "2", "requeued_units_count" => "0",
        "max_requeues" => "0", "requeue_tolerance" => "0.0", "max_reclaims" => "3", "timeout" => "180", "ttl" => "14400"
      )
      expect(described_class.from_meta(meta)).to eq(manifest)
    end

    it "treats absent or empty optional fields as nil" do
      meta = manifest.to_meta.except("revision", "ready_at").merge("revision" => "")
      m = described_class.from_meta(meta)
      expect(m.revision).to be_nil
      expect(m.ready_at).to be_nil
    end

    it "accepts symbol keys" do
      expect(described_class.from_meta(manifest.to_meta.transform_keys(&:to_sym))).to eq(manifest)
    end

    it "raises when a required field is missing" do
      expect { described_class.from_meta(manifest.to_meta.except("total_units")) }.to raise_error(KeyError)
    end

    it "decodes an init_failed manifest with load errors and no units" do
      failed = described_class.new(total_examples: 0, file_counts: {}, file_args: %w[spec], fingerprint: nil,
                                   seed: nil, load_errors: ["spec/broken_spec.rb: NameError: uninitialized constant X"])
      decoded = described_class.from_meta(failed.to_meta.merge("state" => "init_failed"))
      expect(decoded).to eq(failed)
      expect(decoded).to be_init_failed
      expect(decoded).to be_empty
      expect(decoded.unit_ids).to eq([])
    end
  end

  describe "#to_json" do
    it "serializes every field for the report summary" do
      parsed = JSON.parse(manifest.to_json)
      expect(parsed).to include(
        "total_units" => 2, "total_examples" => 5, "seed" => 4242, "fingerprint" => "abc123",
        "revision" => "deadbeef", "ready_at" => 1_700_000_000_000, "load_errors" => [],
        "file_counts" => file_counts, "file_args" => %w[spec/a_spec.rb spec/b_spec.rb]
      )
    end
  end
end
