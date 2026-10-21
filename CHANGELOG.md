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
- The browser client (`assets/`, bundled by `mix issho.build`): `Room`
  over a pluggable transport (`phoenixTransport`, with sockets shared by
  the rooms of a page and tokens renewed), `Presence`, `Awareness` (sent
  latest-wins, received per node), and `SharedDocument` (local changes at
  once, one transaction in flight, others' changes replayed under pending
  ones, refusals, gaps, reconnects that resend only what the server lacks).
- The map engine's TypeScript twin, and `test/corpus`, cases both
  engines must pass.
- An end-to-end test: two clients over WebSockets on a real endpoint.
