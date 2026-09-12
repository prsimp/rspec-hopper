# frozen_string_literal: true

require "digest"
require "json"

module RSpec
  module Hopper
    # Proves that workers loaded the same logical suite, not merely that they were
    # given the same arguments. Computed after loading, over the normalized
    # selection inputs, the ordering strategy name (never the seed), the sorted
    # selected example ids, the optional revision string and the unit type.
    class Fingerprint
      INPUT_KEYS = %w[file_args filter pattern exclude_pattern order example_ids revision unit_type].freeze
      PROC_ADDRESS = /0x[0-9a-f]+@?/
      # Per-input digests are recorded in the manifest so a mismatching worker
      # can name the inputs that differ. Truncated: they are compared with each
      # other, never used as a security boundary, and `meta` stays small.
      DIGEST_LENGTH = 16

      attr_reader :value, :inputs

      class << self
        # @param configuration [RSpec::Core::Configuration] the configured RSpec
        # @param options [RSpec::Core::ConfigurationOptions] the merged options
        # @param example_ids [Array<String>] ids of the selected examples
        # @param file_args [Array<String>] normalized file arguments
        # @param revision [String, nil]
        # @param unit_type [String] "file" or "example"; a build has one unit type
        def compute(configuration:, options:, example_ids:, file_args:, revision: nil, unit_type: "file")
          filter_manager = configuration.filter_manager
          new(
            "file_args" => Array(file_args).map(&:to_s).sort,
            "filter" => {
              "inclusions" => render_rules(filter_manager.inclusions.rules),
              "exclusions" => render_rules(filter_manager.exclusions.rules)
            },
            "pattern" => configuration.pattern.to_s,
            "exclude_pattern" => configuration.exclude_pattern.to_s,
            "order" => ordering_name(options.options[:order]),
            "example_ids" => Array(example_ids).map(&:to_s).sort,
            "revision" => revision&.to_s,
            "unit_type" => unit_type.to_s
          )
        end

        # The strategy name of an `--order` option value, without any seed.
        def ordering_name(option)
          name = option.to_s.split(":").first.to_s
          return "defined" if name.empty?

          name.include?("rand") ? "random" : name
        end

        # Filter rules as deterministic strings: proc addresses are stripped and
        # the project directory (locations are absolute) is replaced by ".".
        def render_rules(rules)
          project_dir = File.expand_path(".")
          rules.map { |key, value| "#{key}=#{render_value(value)}".gsub(PROC_ADDRESS, "").gsub(project_dir, ".") }.sort
        end

        # Renders a filter value without going through the built-in `inspect`
        # for containers. Ruby 3.4 changed `Hash#inspect` from `{"a"=>1}` to
        # `{"a" => 1}`, which would otherwise make the same suite fingerprint
        # differently on either side of that release. Hash pairs are sorted so
        # insertion order cannot change the result either.
        def render_value(value)
          case value
          when Hash
            pairs = value.map { |k, v| "#{render_value(k)} => #{render_value(v)}" }.sort
            "{#{pairs.join(", ")}}"
          when Array
            "[#{value.map { |element| render_value(element) }.join(", ")}]"
          else
            value.inspect
          end
        end

        # A short digest of one input value, stable across Ruby versions
        # because `render_value` already avoids the built-in container inspect.
        def digest(value)
          Digest::SHA256.hexdigest(JSON.generate([canonical(value)]))[0, DIGEST_LENGTH]
        end

        def canonical(object)
          case object
          when Hash then object.keys.map(&:to_s).sort.to_h { |k| [k, canonical(object[k] || object[k.to_sym])] }
          when Array then object.map { |v| canonical(v) }
          else object
          end
        end
      end

      def initialize(inputs)
        @inputs = self.class.canonical(inputs).freeze
        @value = Digest::SHA256.hexdigest(JSON.generate(@inputs)).freeze
      end

      def to_s = value

      def ==(other)
        value == (other.is_a?(Fingerprint) ? other.value : other)
      end
      alias eql? ==

      def hash = value.hash

      def to_json(*) = JSON.generate(inputs, *)

      # The manifest records these, not the inputs themselves: the sorted
      # example-id list of a real suite is hundreds of kilobytes, and `meta`
      # has to stay small. Digests name the inputs that differ; the example-id
      # count turns "example_ids differ" into something an operator can act on.
      def digests
        @digests ||= INPUT_KEYS.to_h { |key| [key, self.class.digest(inputs[key])] }
                               .merge("example_ids_count" => inputs["example_ids"].size)
                               .freeze
      end

      # One line describing the inputs, for mismatch messages.
      def summary
        [
          "file_args=#{inputs["file_args"].inspect}",
          "filter=#{inputs["filter"].inspect}",
          "pattern=#{inputs["pattern"].inspect}",
          "exclude_pattern=#{inputs["exclude_pattern"].inspect}",
          "order=#{inputs["order"]}",
          "example_ids=#{inputs["example_ids"].size}",
          "revision=#{inputs["revision"].inspect}",
          "unit_type=#{inputs["unit_type"]}"
        ].join(", ")
      end

      # Explains why a worker's fingerprint differs from the manifest's.
      module Mismatch
        module_function

        # @param local [Fingerprint] this worker's fingerprint
        # @param remote_value [String] the manifest's fingerprint
        # @param remote_digests [String, Hash, nil] the initializer's per-input
        #   digests, as recorded in the manifest, when available
        def explain(local, remote_value, remote_digests = nil)
          lines = ["suite fingerprint mismatch: this worker computed #{local.value} " \
                   "but the build manifest records #{remote_value}"]
          remote = parse(remote_digests)
          lines.concat(differences(local.digests, remote)) if remote
          lines << "local inputs: #{local.summary}"
          lines.join("\n")
        end

        # Names the inputs whose digests differ. Only the example ids carry a
        # count, because that is the difference an operator cannot see from
        # their own command line: a stale checkout selecting a different set.
        def differences(local, remote)
          keys = Fingerprint::INPUT_KEYS.reject { |key| local[key] == remote[key] }
          if keys.empty?
            return ["recorded inputs are identical; the fingerprint algorithm may differ between gem versions"]
          end

          lines = ["differing inputs: #{keys.join(", ")}"]
          lines << "  #{example_id_counts(local, remote)}" if keys.include?("example_ids")
          lines
        end

        # Equal counts with differing digests mean a checkout that renames or
        # moves examples rather than one that adds or removes them.
        def example_id_counts(local, remote)
          mine = local["example_ids_count"]
          theirs = remote["example_ids_count"]
          return "example_ids: this worker selects #{mine}, the initializer selected #{theirs}" unless mine == theirs

          "example_ids: this worker and the initializer both select #{mine}, but the ids differ"
        end

        def parse(remote_digests)
          case remote_digests
          when nil, "" then nil
          when Hash then remote_digests.transform_keys(&:to_s)
          else
            parsed = JSON.parse(remote_digests.to_s)
            parsed.is_a?(Hash) ? parsed.transform_keys(&:to_s) : nil
          end
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
