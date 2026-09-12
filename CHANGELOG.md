# Changelog

## [Unreleased]

- `--unit example`: one work unit per selected example instead of per spec file.
  Examples are queued in the order RSpec would run them under the build seed, run
  through their file's group with the selection narrowed to the one example (context
  hooks fire per unit), and a requeue reruns only the failed example. The unit type is
  part of the suite fingerprint, is recorded in the manifest and the report summary
  (`unit_type`), and `--failed-out` then lists example ids. `--unit file` stays the
  default and its Redis layout is unchanged apart from the new `unit_type` meta field.
- `ExampleSubset`, the second sanctioned touch of rspec-core internals, guarded by a
  contract spec like `ExampleReset`.
- Warn at boot when a gem wraps `RSpec::Core::Runner#run_specs`, which the worker's
  runner replaces: that wrapper never runs, and for datadog-ci it is where the test
  session and module are started. Documents starting such lifecycles in suite hooks.
- Point the gem's `documentation_uri` at the design document.

## [0.1.0] - 2026-09-11

- Initial Phase 1 implementation: file-level work units distributed through
  Redis Streams, requeue and reclaim accounting, an append-only attempt log,
  a `work` subcommand with `--processes` and two boot modes, and a `report`
  subcommand that produces the build verdict.
