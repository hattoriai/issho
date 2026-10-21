# Changelog

All notable changes to Issho are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Issho follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Agents over MCP: `Issho.MCP`, a [Sake](https://hex.pm/packages/sake)
  server the app serves as it serves MCP (HTTP or stdio, its own
  authorization or none, on its own endpoint or mounted in its server).
  An agent joins a room, looks around, points, says what it is doing,
  reads and changes documents, and leaves; people see it there. It acts
  under the app's policy, as the actor the app says: a person's agent on
  their behalf, the app's bot or the system acting as itself, or both at
  once, from the call or per endpoint (`Issho.MCP.Session`,
  `Issho.MCP.Setup`). Sake is a dependency of Issho.
- `Issho.Agents`: an agent's lasting presence in a room for front ends
  without a lasting connection (an MCP server, a webhook), from its first
  call until it leaves or has been idle for `:idle` (ten minutes).
- `Issho.Participant.people/1`: the room's people, and where each is.
- Grants: `Issho.Live.grant/4` signs a room's grant for a component's
  browser half and remembers it; the `Issho.Live` hook renews it on the
  browser's `"issho:grant"` event, after asking the policy again.
  `requestGrant(hook, room)` asks for one from the browser. One grant
  serves every component of the page in the room.

- `upgrade/1`, an engine's optional callback: a stored document of
  another engine version, or one a library saved before Issho, opens
  upgraded and is saved upgraded with its next transaction.
- Batching in the browser: `room.open(id, { batch: { delay, maxOps } })`
  makes changes close together one transaction, while it has not been
  sent. `SharedDocument#hold()` and `release()` keep transactions from
  going while a person composes text; `flush()` sends the batch now.
- `{:initial, content}` from a store's `load/2`: a document starts from
  the content your app already has, before anyone opened it together.
- Presence says what each person may do: `can`, `"write"` when any of
  their tabs may write, `"read"` for someone only viewing.
- TypeScript declarations in the package (`priv/static/types`), named by
  `package.json`'s `types`: a component library's TypeScript imports
  `issho` with its types.

### Fixed

- The Phoenix transport takes a room offline at the browser's offline
  event and at a push with no reply, and waits out a join the socket's
  channel limit refused ("too many channels joined") instead of ending
  the room.
- `joinRoom` gives a second component of the page the room once it has
  joined, not while it is joining (when it still read as `"read"`).
- An earlier revision (`content_at/3`) replays each transaction of the
  journal as it was accepted, not their operations as one: revision 0,
  and engines that limit a transaction's operations, rebuild.
- `use Issho.Binding` waits for its engine to compile, so it delegates
  the engine's optional callbacks (`upgrade/1`) whatever the order.

## [0.1.0] - 2026-10-21

The first release: the server core, `Issho.Live`, agents from Elixir,
and the browser client's core. The cursor overlay, following, the
bindings of Kotoba and Masu, MCP and the installer come next.

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
- Drafts: pending transactions kept per tab session across reloads, in
  IndexedDB or memory, sent when the document opens again; a draft of
  another epoch is reported and kept aside.
- Document specs from server code (`Issho.Documents.open/4`), documents
  with no store (`Issho.Store.None`), and `:on_transaction` hooks, run
  once per accepted transaction before it is saved, able to refuse it.
- `Issho.Live`: a LiveView in a room, the same session as a channel's,
  with the room's events sent to its components or to the LiveView.
