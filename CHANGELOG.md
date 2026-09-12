# Changelog

## [Unreleased]

- Point the gem's `documentation_uri` at the design document.

## [0.1.0] - 2026-09-11

- Initial Phase 1 implementation: file-level work units distributed through
  Redis Streams, requeue and reclaim accounting, an append-only attempt log,
  a `work` subcommand with `--processes` and two boot modes, and a `report`
  subcommand that produces the build verdict.
