# Changelog

All notable changes to Issho are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Issho follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The contracts: `Issho.Actor`, `Issho.Identity`, `Issho.Policy`,
  `Issho.Engine`, `Issho.Place`, `Issho.Binding` and `Issho.Store`.
- `Issho.Authority`: one process per document across a cluster that
  orders transactions, applies each once (receipts), saves with the
  store's compare-and-swap before it confirms and broadcasts, keeps a
  journal, and reads any revision of the epoch.
- `Issho.Engine.Map`, the engine of shared maps and of the tests.
- `Issho.Store.Memory`, for development and tests.
- `Issho.Channel` and `Issho.Token`: rooms joined with signed tokens,
  the policy asked on join, on every message and before each change goes
  out, read-only tokens, nested documents of a room, and `Issho.revoke/3`.
- `Issho.Presence` and `Issho.Awareness`: who is in a room, and where,
  in batched frames per room and node.
- `Issho.join_as/4` and `Issho.Participant`: agents and jobs in a room
  from Elixir.
- `Issho.Test`: an isolated instance per test, and `replays?/2`.
