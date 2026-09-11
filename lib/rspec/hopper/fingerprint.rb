# frozen_string_literal: true

require "digest"
require "json"

module RSpec
  module Hopper
    # Proves that workers loaded the same logical suite, not merely that they were
    # given the same arguments. Computed after loading, over the normalized
    # selection inputs, the ordering strategy name (never the seed), the sorted
    # selected example ids and the optional revision string.
    class Fingerprint
      INPUT_KEYS = %w[file_args filter pattern exclude_pattern order example_ids revision].freeze
      PROC_ADDRESS = /0x[0-9a-f]+@?/

      attr_reader :value, :inputs

      class << self
        # @param configuration [RSpec::Core::Configuration] the configured RSpec
        # @param options [RSpec::Core::ConfigurationOptions] the merged options
        # @param example_ids [Array<String>] ids of the selected examples
        # @param file_args [Array<String>] normalized file arguments
        # @param revision [String, nil]
        def compute(configuration:, options:, example_ids:, file_args:, revision: nil)
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
            "revision" => revision&.to_s
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

      # One line describing the inputs, for mismatch messages.
      def summary
        [
          "file_args=#{inputs["file_args"].inspect}",
          "filter=#{inputs["filter"].inspect}",
          "pattern=#{inputs["pattern"].inspect}",
          "exclude_pattern=#{inputs["exclude_pattern"].inspect}",
          "order=#{inputs["order"]}",
          "example_ids=#{inputs["example_ids"].size}",
          "revision=#{inputs["revision"].inspect}"
        ].join(", ")
      end

      # Explains why a worker's fingerprint differs from the manifest's.
      module Mismatch
        module_function

        # @param local [Fingerprint] this worker's fingerprint
        # @param remote_value [String] the manifest's fingerprint
        # @param remote_inputs [String, Hash, nil] the initializer's inputs, when available
        def explain(local, remote_value, remote_inputs = nil)
          lines = ["suite fingerprint mismatch: this worker computed #{local.value} " \
                   "but the build manifest records #{remote_value}"]
          remote = parse(remote_inputs)
          if remote
            lines.concat(differences(local.inputs, remote))
          else
            lines << "local inputs: #{local.summary}"
          end
          lines.join("\n")
        end

        def differences(local, remote)
          keys = Fingerprint::INPUT_KEYS.reject { |key| local[key] == remote[key] }
          return ["inputs are identical; the fingerprint algorithm may differ between gem versions"] if keys.empty?

          lines = ["differing inputs: #{keys.join(", ")}"]
          keys.each do |key|
            next if key == "example_ids"

            lines << "  #{key}: local=#{local[key].inspect} remote=#{remote[key].inspect}"
          end
          if keys.include?("example_ids")
            differing = (local["example_ids"] - remote["example_ids"]) | (remote["example_ids"] - local["example_ids"])
            lines << "  example_ids: #{differing.size} differ (local #{local["example_ids"].size}, " \
                     "remote #{remote["example_ids"].size})"
          end
          lines
        end

        def parse(remote_inputs)
          case remote_inputs
          when nil, "" then nil
          when Hash then Fingerprint.canonical(remote_inputs)
          else Fingerprint.canonical(JSON.parse(remote_inputs.to_s))
          end
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
