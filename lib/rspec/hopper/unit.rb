# frozen_string_literal: true

module RSpec
  module Hopper
    UNIT_TYPES = %w[file example].freeze

    # A schedulable unit of work: one spec file (`file`, the default) or one
    # example (`example`, `--unit example`). The `type` travels with the queue
    # entry, the reservation and the manifest.
    Unit = Data.define(:id, :type) do
      def self.file(path) = new(id: path, type: "file")
      def self.example(example_id) = new(id: example_id, type: "example")

      def initialize(id:, type:)
        type = type.to_s
        raise ArgumentError, "unknown unit type #{type.inspect}; expected one of #{UNIT_TYPES.join(", ")}" unless
          UNIT_TYPES.include?(type)

        super(id: id.to_s, type: type)
      end

      def file? = type == "file"
      def example? = type == "example"

      def to_h = { "id" => id, "type" => type }
    end
  end
end
