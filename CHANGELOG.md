# Changelog

All notable changes to Issho are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Issho follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - 2026-10-21

### Added

- An agent's pointer goes where it works on the page, and glides there:
  a component says where a place of its document is (`locate(element,
  at => box)` in the `issho` package), and the pointer of an agent at
  work in it goes to that box (its caret, a node, a cell), follows it as
  the document changes, and moves from place to place, and from component
  to component, as a hand would (`--issho-agent-glide`, 320ms).
- At a place a component located, the pointer is the arrow only: the
  component names the agent there (Kotoba's caret has its name), so the
  name is not shown twice.
- `Pointing` carries the agent's place in its document (`at`).

## [0.2.0] - 2026-10-21

Agents, and pages of many components. An agent joins a room, however it
reaches the app (its own model through an API, or MCP), and works as a
person does, in each component's own terms;
the components of a page share one room: its connection, its people, its
grant, its form barrier and its undo, and the page itself is a live space.
Kotoba, Hakushi and Masu run on it.

### Added

- Tools for agents, however they reach your app: `Issho.Tool`, a tool
  in Issho's own terms (a name, a description, a JSON Schema of its
  arguments, and what it does as the agent of an `Issho.Tool.Context`),
  and `Issho.Tools.room/0`, Issho's tools for rooms: join, look around,
  read, point, say what you do, change, leave. The components bring
  theirs. An agent acts under the app's policy, as the actor the app
  says: a person's agent on their behalf, the app's bot or the system as
  itself.
- Your app's own model, through its API: `Issho.Tools.schemas/1` gives
  the tools' definitions for a request, and `Issho.Tools.call/4` runs a
  tool use, as the app's agent. No MCP needed.
- MCP clients: `use Issho.MCP, tools: ...` serves the same tools as a
  [Sake](https://hex.pm/packages/sake) server, served as the app serves
  MCP (HTTP or stdio, its own authorization or none); who a caller is
  comes from the call or the endpoint (`Issho.MCP.Session`,
  `Issho.MCP.Setup`). Sake is an optional dependency. With Sake 0.4.4, a
  tool gets its arguments as the client sent them (`absent: :omit`).
- `Issho.Agents`: an agent's lasting presence in a room for front ends
  without a lasting connection (an MCP server, a webhook), from its first
  call until it leaves or has been idle for `:idle` (ten minutes).
- `Issho.Participant.people/1`: the room's people, where each is, and
  each session's awareness state.
- Agents act on what someone selected: `Issho.Tools.person_of/2` and
  `place_of/3` find a person of the room by name or key, and their place
  in a document or their whole state, for a component's tool that takes
  `of` ("rewrite what Ada selected").
- `Issho.Participant.authorize/2`: the room's policy, for a component
  whose data is not in Issho's documents (a grid of the app's database),
  which writes it itself.
- The page as a live space: `Issho.Components.pointers/1` and the
  `IsshoPointers` hook draw each person's pointer and clicks over the
  whole page, on the same element of everyone's own page (an element and
  a point in it, never screen pixels), with a marker at the edge of the
  viewport that scrolls to it. A component that draws its own cursors
  takes over (`data-issho-cursor="own"`); nothing is shared over
  `data-issho-private`, a password field or a window in the background;
  an agent at work in a document is drawn at its component
  (`data-issho-doc`).
- `Issho.Live.merge/2`, `awareness/1` and `states/1`: the components of a
  LiveView that share its session in a room each merge their own keys,
  and one that draws the others itself reads the room's states.
- The look is the app's: every piece of `issho.css` a custom property
  (the avatars' tint, ring, initials and shape, the badges, the pointers'
  names), a `:person` slot for the list the server renders, and
  `configure({person, pointer})` in the browser to draw a person or a
  pointer with the app's own markup. The default avatars are a tint of
  the person's colour, a fine ring, and their initials in a deeper shade.
- `import_deps: [:issho]` gives formatters `Issho.Tool`'s `arg`.
- Grants: `Issho.Live.grant/4` signs a room's grant for a component's
  browser half and remembers it; the `Issho.Live` hook renews it on the
  browser's `"issho:grant"` event, after asking the policy again.
  `requestGrant(hook, room)` asks for one from the browser. One grant
  serves every component of the page in the room.
- The people of a room, one list for the page: `Issho.Components.people/1`
  (with a grant, kept live in the browser by the `IsshoPeople` hook of
  `Hooks`; or rendered by a LiveView in the room), `drawPeople` in the
  browser. Agents and the app are marked, with whom an agent acts for;
  viewers are marked; a person's status shows.
- Issho's theme: `issho.css`, and `issho-sumi.css` for the Sumi theme, in
  the package's `priv/static`; every value a custom property, people's
  colours from `--issho-person-1` to `-8`.
- `releaseRoom`: each component that asked for a room holds it, and the
  page leaves the room when the last lets go.
- `holdForm`: a form with shared components publishes what the server
  accepted. On submit it locks them, waits for each to send what it has
  and note the accepted revision in its own field, then submits again; a
  component that cannot stops the submit, with its reason.
- Undo across a page: `pageHistory` keeps the order of a person's steps
  in every component, each component its own steps (`HistoryOwner`), so
  undo takes back the last change wherever it was made.

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
- A tool's argument that is a list of objects comes with each object's
  declared fields, checked; a field given as `null` is not given, as an
  argument is not (an MCP layer may fill each declared field with null).
- A room without presence (`presence: false`) has no people list to ask:
  `Issho.Participant.people/1` gives its people by their states.
- The live people list says the `label` it is given.

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
