# frozen_string_literal: true

require "json"

module RSpec
  module Hopper
    # Written once by the initializing worker into `meta`. For file units the
    # unit ids are the keys of `file_counts` in order and are not stored
    # separately; for example units they are stored as `unit_ids`.
    Manifest = Data.define(
      :total_units, :total_examples, :unit_type, :unit_ids, :file_counts, :file_args,
      :fingerprint, :fingerprint_digests, :seed, :ready_at, :revision, :load_errors
    ) do
      # Builds a Manifest from `meta` exactly as HGETALL returns it (all string
      # values). Runtime fields such as `state` and `finalized_count` are ignored.
      def self.from_meta(meta)
        meta = meta.transform_keys(&:to_s)
        new(
          total_units: meta.fetch("total_units"),
          total_examples: meta.fetch("total_examples"),
          unit_type: meta.fetch("unit_type", "file"),
          unit_ids: meta["unit_ids"] && JSON.parse(meta["unit_ids"]),
          file_counts: JSON.parse(meta.fetch("file_counts", "{}")),
          file_args: JSON.parse(meta.fetch("file_args", "[]")),
          fingerprint: meta["fingerprint"],
          fingerprint_digests: parse_digests(meta["fingerprint_digests"]),
          seed: meta["seed"],
          ready_at: meta["ready_at"],
          revision: meta["revision"],
          load_errors: JSON.parse(meta.fetch("load_errors", "[]"))
        )
      end

      # Per-input digests of the initializer's fingerprint, for mismatch
      # messages; absent from builds initialized by an older worker.
      def self.parse_digests(value)
        return nil if value.nil? || value.empty?

        digests = JSON.parse(value)
        digests.is_a?(Hash) ? digests : nil
      rescue JSON::ParserError
        nil
      end

      # Optional fields are nil when absent rather than empty strings, so a
      # manifest read back from `meta` equals the one that was written.
      def self.normalize_optional(fingerprint:, fingerprint_digests:, seed:, ready_at:, revision:)
        {
          fingerprint: presence(fingerprint)&.to_s,
          fingerprint_digests: presence(fingerprint_digests)&.transform_keys(&:to_s)&.freeze,
          seed: presence(seed)&.then { |s| Integer(s) },
          ready_at: presence(ready_at)&.then { |ms| Integer(ms) },
          revision: presence(revision)&.to_s
        }
      end

      # File units are the files themselves, so their ids need not be given.
      def self.unit_ids_for(type, unit_ids, counts)
        ids = unit_ids || (type == "file" ? counts.keys : nil)
        raise ArgumentError, "unit_ids are required for #{type} units" if ids.nil?

        ids.map(&:to_s).freeze
      end

      def self.presence(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?) ? nil : value
      end

      def initialize(total_examples:, file_counts:, file_args:, unit_type: "file", unit_ids: nil, fingerprint: nil,
                     fingerprint_digests: nil, seed: nil, total_units: nil, ready_at: nil, revision: nil,
                     load_errors: [])
        counts = file_counts.to_h { |path, count| [path.to_s, Integer(count)] }.freeze
        type = unit_type.to_s
        raise ArgumentError, "unknown unit type #{type.inspect}" unless UNIT_TYPES.include?(type)

        ids = self.class.unit_ids_for(type, unit_ids, counts)
        units = Integer(total_units || ids.size)
        raise ArgumentError, "total_units (#{units}) does not match the number of unit ids (#{ids.size})" if
          units != ids.size

        super(
          total_units: units,
          total_examples: Integer(total_examples),
          unit_type: type,
          unit_ids: ids,
          file_counts: counts,
          file_args: Array(file_args).map(&:to_s).freeze,
          load_errors: Array(load_errors).map(&:to_s).freeze,
          **self.class.normalize_optional(fingerprint: fingerprint, fingerprint_digests: fingerprint_digests,
                                          seed: seed, ready_at: ready_at, revision: revision)
        )
      end

      def file_units? = unit_type == "file"
      def example_units? = unit_type == "example"

      def init_failed? = load_errors.any?

      def empty? = total_examples.zero?

      # Hash of String => String for HSET. Nested fields are JSON-encoded;
      # nil fields are omitted rather than written as empty strings. File
      # unit ids are implied by `file_counts` and not written, so the meta of
      # a file-unit build is what 0.1.0 wrote plus `unit_type`.
      def to_meta
        meta = {
          "total_units" => total_units.to_s,
          "total_examples" => total_examples.to_s,
          "unit_type" => unit_type,
          "file_counts" => JSON.generate(file_counts),
          "file_args" => JSON.generate(file_args),
          "load_errors" => JSON.generate(load_errors)
        }
        meta["unit_ids"] = JSON.generate(unit_ids) unless file_units?
        optional_meta.each { |key, value| meta[key] = value unless value.nil? }
        meta
      end

      def to_json(*args) = to_h.to_json(*args)

      private

      # Written only when set; an absent field must not become an empty string.
      def optional_meta
        {
          "fingerprint" => fingerprint,
          "fingerprint_digests" => fingerprint_digests && JSON.generate(fingerprint_digests),
          "seed" => seed&.to_s,
          "ready_at" => ready_at&.to_s,
          "revision" => revision
        }
      end
    end
  end
end
