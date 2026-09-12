# frozen_string_literal: true

module RSpec
  module Hopper
    UNIT_TYPES = %w[file].freeze

    # A schedulable unit of work. Phase 1 units are spec files; the `type`
    # field exists so example-level units can be added without a schema change.
    Unit = Data.define(:id, :type) do
      def self.file(path) = new(id: path, type: "file")

      def to_h = { "id" => id, "type" => type }
    end
  end
end
