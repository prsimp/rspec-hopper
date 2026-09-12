# Changelog

## [Unreleased]

- Warn at boot when a gem wraps `RSpec::Core::Runner#run_specs`, which the worker's
  runner replaces: that wrapper never runs, and for datadog-ci it is where the test
  session and module are started. Documents starting such lifecycles in suite hooks.
- Point the gem's `documentation_uri` at the design document.

## [0.1.0] - 2026-09-11

- Initial Phase 1 implementation: file-level work units distributed through
  Redis Streams, requeue and reclaim accounting, an append-only attempt log,
  a `work` subcommand with `--processes` and two boot modes, and a `report`
  subcommand that produces the build verdict.
