# Changelog

## [Unreleased]

- Initial Phase 1 implementation: file-level work units distributed through
  Redis Streams, requeue and reclaim accounting, an append-only attempt log,
  a `work` subcommand with `--processes` and two boot modes, and a `report`
  subcommand that produces the build verdict.
