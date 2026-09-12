# frozen_string_literal: true

module RSpec
  module Hopper
    module CLI
      # Formatter output must be per child process under `--processes N`. The
      # supervisor strips every `--format`/`--out` option from the RSpec
      # arguments in the parent and re-applies them in each child: `%{n}` in an
      # `--out` path becomes that child's TEST_ENV_NUMBER, and a formatter
      # without an `--out` of its own is given a file under {DEFAULT_DIR}.
      #
      # Children therefore never write to a shared console stream. One build no
      # longer prints one RSpec summary per process (an idle child used to
      # announce "0 examples, 0 failures" for the whole build); the closing word
      # belongs to `rspec-hopper report`, which is the only thing that sees
      # every worker's results.
      module FormatterArgs
        FORMAT_FLAGS = %w[--format -f].freeze
        OUT_FLAGS = %w[--out -o].freeze
        PLACEHOLDER = "%{n}" # rubocop:disable Style/FormatStringToken
        DEFAULT_FORMAT = "progress"
        DEFAULT_DIR = "tmp/rspec-hopper"
        # Extensions for the formatters that write a recognised file format;
        # everything else (progress, documentation, a custom class) gets .txt.
        EXTENSIONS = { "json" => "json", "j" => "json", "html" => "html", "h" => "html", "junit" => "xml" }.freeze
        DEFAULT_EXTENSION = "txt"

        module_function

        # Splits the formatter options out of `rspec_args`.
        #
        # @return [Array(Array<String>, Array<Array(String, String)>)] the
        #   remaining arguments in original order, and the formatter pairs, each
        #   normalized to `["--format", value]` or `["--out", value]`, in the
        #   order they appeared. Arguments after `--` are never touched.
        def split(rspec_args)
          remaining = []
          pairs = []
          args = rspec_args.dup
          until args.empty?
            arg = args.shift
            if arg == "--"
              remaining.push(arg, *args)
              break
            end
            flag, value, needs_next = recognise(arg)
            if flag.nil? || (needs_next && args.empty?) # unknown, or a dangling flag RSpec should report
              remaining << arg
            else
              pairs << [flag, needs_next ? args.shift : value]
            end
          end
          [remaining, pairs]
        end

        # Groups pairs the way RSpec's own parser does: an `--out` attaches to
        # the preceding `--format`, or to the default progress formatter when
        # there is none.
        #
        # @return [Array<Array(String, String, nil)>] `[formatter, out or nil]`
        def entries(pairs)
          pairs.each_with_object([]) do |(flag, value), list|
            if flag == "--format"
              list << [value, nil]
            else
              list << [DEFAULT_FORMAT, nil] if list.empty?
              list[-1] = [list[-1][0], value]
            end
          end
        end

        # Whether any child formatter would be given a generated output path.
        def defaults_needed?(pairs)
          list = entries(pairs)
          list.empty? || list.any? { |(_formatter, out)| out.nil? }
        end

        # The flat argument list to prepend to a child's RSpec arguments. Every
        # formatter comes back with an explicit `--out`, so no child writes to
        # the console.
        #
        # @param pairs [Array<Array(String, String)>] from {split}
        # @param env_number [String] the child's TEST_ENV_NUMBER ("" or "2"..)
        # @param label [String, nil] the child's worker id, used in generated names
        # @param dir [String] where generated output files go
        def for_child(pairs, env_number, label: nil, dir: DEFAULT_DIR)
          list = entries(pairs)
          list = [[DEFAULT_FORMAT, nil]] if list.empty?
          seen = Hash.new(0)
          list.flat_map do |formatter, out|
            path = out ? out.gsub(PLACEHOLDER, env_number) : generated_path(dir, label, formatter, env_number, seen)
            ["--format", formatter, "--out", path]
          end
        end

        # `tmp/rspec-hopper/w-2-json.json`, numbered when one child names the
        # same formatter twice.
        def generated_path(dir, label, formatter, env_number, seen)
          slug = slugify(formatter)
          occurrence = (seen[slug] += 1)
          suffix = occurrence > 1 ? "-#{occurrence}" : ""
          base = label.to_s.empty? ? "worker#{env_number}" : label.to_s
          File.join(dir, "#{slugify(base)}-#{slug}#{suffix}.#{EXTENSIONS.fetch(slug, DEFAULT_EXTENSION)}")
        end

        def slugify(value)
          slug = value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
          slug.empty? ? DEFAULT_FORMAT : slug
        end

        # @return [Array(String, String, Boolean), nil] normalized flag, inline
        #   value (or nil), and whether the value is the next argument.
        def recognise(arg)
          FORMAT_FLAGS.each { |f| (m = match(f, arg)) and return ["--format", *m] }
          OUT_FLAGS.each { |f| (m = match(f, arg)) and return ["--out", *m] }
          nil
        end

        def match(flag, arg)
          return [nil, true] if arg == flag
          return [arg.delete_prefix("#{flag}="), false] if flag.start_with?("--") && arg.start_with?("#{flag}=")
          return [arg.delete_prefix(flag), false] if !flag.start_with?("--") && arg.start_with?(flag) && arg.size > 2

          nil
        end
      end
    end
  end
end
