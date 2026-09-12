# frozen_string_literal: true

module RSpec
  module Hopper
    # Command-line entry point: dispatches `work` and `report`.
    module CLI
      # Raised by a subcommand parser when `-h`/`--help` is given; carries the
      # help text so the caller can print it to stdout and exit 0.
      class HelpRequested < StandardError
        attr_reader :text

        def initialize(text)
          @text = text
          super("help requested")
        end
      end

      USAGE = <<~USAGE
        Usage: rspec-hopper <command> [options]

        Commands:
          work     run a worker: boot the suite, join the build, consume the queue
          report   wait for a build to finish and print the verdict

        Options:
          -h, --help       show this help
          -v, --version    print the version

        Run `rspec-hopper work --help` or `rspec-hopper report --help` for the
        options of each command.
      USAGE

      module_function

      # @return [Integer] process exit code
      def run(argv, out: $stdout, err: $stderr)
        command, *rest = argv
        case command
        when "work" then Work.run(rest, out: out, err: err)
        when "report" then Report.run(rest, out: out, err: err)
        when "-v", "--version"
          out.puts "rspec-hopper #{VERSION}"
          ExitCode::OK
        when "-h", "--help", "help"
          out.puts USAGE
          ExitCode::OK
        else
          err.puts(command.nil? ? "rspec-hopper: no command given" : "rspec-hopper: unknown command #{command.inspect}")
          err.puts USAGE
          ExitCode::INFRASTRUCTURE
        end
      rescue HelpRequested => e
        out.puts e.text
        ExitCode::OK
      rescue UsageError => e
        err.puts "rspec-hopper: #{e.message}"
        ExitCode::INFRASTRUCTURE
      end
    end
  end
end
