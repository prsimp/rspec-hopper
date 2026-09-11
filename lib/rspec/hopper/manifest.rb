# frozen_string_literal: true

require "json"

module RSpec
  module Hopper
    # Written once by the initializing worker into `meta`. Unit ids are the keys
    # of `file_counts` in order; they are not stored separately.
    Manifest = Data.define(
      :total_units, :total_examples, :file_counts, :file_args,
      :fingerprint, :seed, :ready_at, :revision, :load_errors
    ) do
      # Builds a Manifest from `meta` exactly as HGETALL returns it (all string
      # values). Runtime fields such as `state` and `finalized_count` are ignored.
      def self.from_meta(meta)
        meta = meta.transform_keys(&:to_s)
        new(
          total_units: meta.fetch("total_units"),
          total_examples: meta.fetch("total_examples"),
          file_counts: JSON.parse(meta.fetch("file_counts", "{}")),
          file_args: JSON.parse(meta.fetch("file_args", "[]")),
          fingerprint: meta["fingerprint"],
          seed: meta["seed"],
          ready_at: meta["ready_at"],
          revision: meta["revision"],
          load_errors: JSON.parse(meta.fetch("load_errors", "[]"))
        )
      end

      def initialize(total_examples:, file_counts:, file_args:, fingerprint: nil, seed: nil,
                     total_units: file_counts.size, ready_at: nil, revision: nil, load_errors: [])
        counts = file_counts.to_h { |path, count| [path.to_s, Integer(count)] }.freeze
        units = Integer(total_units)
        if units != counts.size
          raise ArgumentError, "total_units (#{units}) does not match file_counts.size (#{counts.size})"
        end

        super(
          total_units: units,
          total_examples: Integer(total_examples),
          file_counts: counts,
          file_args: Array(file_args).map(&:to_s).freeze,
          fingerprint: presence(fingerprint)&.to_s,
          seed: presence(seed)&.then { |s| Integer(s) },
          ready_at: presence(ready_at)&.then { |ms| Integer(ms) },
          revision: presence(revision)&.to_s,
          load_errors: Array(load_errors).map(&:to_s).freeze
        )
      end

      def unit_ids = file_counts.keys

      def init_failed? = load_errors.any?

      def empty? = total_examples.zero?

      # Hash of String => String for HSET. Nested fields are JSON-encoded;
      # nil fields are omitted rather than written as empty strings.
      def to_meta
        meta = {
          "total_units" => total_units.to_s,
          "total_examples" => total_examples.to_s,
          "file_counts" => JSON.generate(file_counts),
          "file_args" => JSON.generate(file_args),
          "load_errors" => JSON.generate(load_errors)
        }
        meta["fingerprint"] = fingerprint unless fingerprint.nil?
        meta["seed"] = seed.to_s unless seed.nil?
        meta["ready_at"] = ready_at.to_s unless ready_at.nil?
        meta["revision"] = revision unless revision.nil?
        meta
      end

      def to_json(*args) = to_h.to_json(*args)

      private

      def presence(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?) ? nil : value
      end
    end
  end
end
