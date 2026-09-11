# frozen_string_literal: true

module RSpec
  module Hopper
    module CLI
      # Formatter output must be per child process under `--processes N`. The
      # supervisor strips every `--format`/`--out` option from the RSpec
      # arguments in the parent and re-applies them in each child, substituting
      # `%{n}` in `--out` paths with the child's TEST_ENV_NUMBER value.
      module FormatterArgs
        FORMAT_FLAGS = %w[--format -f].freeze
        OUT_FLAGS = %w[--out -o].freeze
        PLACEHOLDER = "%{n}" # rubocop:disable Style/FormatStringToken

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

        # The flat argument list to prepend to a child's RSpec arguments.
        #
        # @param pairs [Array<Array(String, String)>] from {split}
        # @param env_number [String] the child's TEST_ENV_NUMBER ("" or "2"..)
        def for_child(pairs, env_number)
          pairs.flat_map do |flag, value|
            [flag, flag == "--out" ? value.gsub(PLACEHOLDER, env_number) : value]
          end
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
