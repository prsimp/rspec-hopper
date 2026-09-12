# frozen_string_literal: true

require_relative "lib/rspec/hopper/version"

Gem::Specification.new do |spec|
  spec.name = "rspec-hopper"
  spec.version = RSpec::Hopper::VERSION
  spec.authors = ["Paul Simpson"]
  spec.email = ["prsimp@gmail.com"]

  spec.summary = "Distribute an RSpec suite across CI workers through Redis Streams."
  spec.description = <<~DESC.strip
    rspec-hopper feeds spec files to many CI workers through a shared Redis,
    requeues flaky work, reclaims work from dead workers, and produces one
    authoritative pass/fail verdict for the whole build.
  DESC
  spec.homepage = "https://github.com/prsimp/rspec-hopper"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/prsimp/rspec-hopper"
  spec.metadata["changelog_uri"] = "https://github.com/prsimp/rspec-hopper/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://github.com/prsimp/rspec-hopper/blob/main/docs/DESIGN.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml docker-compose.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "json"
  spec.add_dependency "redis", ">= 5.0", "< 6.0"
  spec.add_dependency "rspec-core", ">= 3.12", "< 4.0"
end
