# Changelog

All notable changes to Issho are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Issho follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-10-23

The room's events, shared state without an engine, comments on any
component, and agents that people see at work and can stop.

### Added

- Issho's events of people: `"person.joined"` when an actor's first
  session comes into a room and `"person.left"` when its last goes, once
  in the cluster (from the node of that session); `"selection.changed"`
  when a session's place changes, with the place.
- Every event is a `[:issho, :event]` telemetry event, with the event and
  the PubSub, for an app's own handlers.
- A LiveView's components hear the room's events they name:
  `Issho.Live.subscribe/3`'s `:events` (names, `"kind.*"`, or `:all`),
  as `{"event", room, event}`. `Issho.Events.match?/2`.
- A participant hears the room's events with `events: true`
  (`Issho.join_as/4`), as `"event"` messages, but those it made happen
  itself, under the policy's `:read`.
- Agents wait for what people do: an agent of `Issho.Agents` keeps the
  room's events since it last asked (the last 100), and
  `Issho.Agents.wait/5` and the `wait_for_events` room tool give them,
  or wait up to a minute for the next.
- `Issho.Event.to_map/1`: an event as JSON, for a model or a browser.
- Shared state without an engine of your own: `Issho.State`, a map
  document as a LiveView assign that stays up to date (`assign/5`),
  changed with `change/3` and the operations `set/2`, `delete/1`,
  `increment/2`, `insert/3`, `move/3` and `remove/2`; `get/2` reads
  through lists by id. The [Shared state](guides/state.md) guide.
- The map engine's lists of items by id (version 2): `insert` and `move`
  (within a list or to another), placed `after` or `before` an item or
  `at` the start or the end, and paths through a list by an item's id.
  Concurrent adds and moves merge; a change of an item that is gone does
  nothing. Its browser twin and the corpus alike.
- `update_state`, a room tool: an agent changes a shared state in the
  map engine's operations.

- Comments and threads: `Issho.Comments`, threads on a place of any
  component (or the page), with replies, edits and deletes by their
  authors, reactions, @mentions, resolve and reopen. A room's threads are
  Issho's own document of the room (`"board:42/issho.comments"`), with
  its engine (`Issho.Engine.Comments`), its browser twin
  (`commentsEngine`) and a corpus both run. Each comment's author and
  time are held to the writer's signed identity and the server's clock.
  The events `"thread.created"`, `"comment.created"`, `"comment.edited"`,
  `"comment.deleted"`, `"thread.resolved"` and `"thread.reopened"`. The
  [Comments](guides/comments.md) guide.
- Comments on the page: `Issho.Components.comments/1` (the LiveComponent
  `Issho.Live.Comments`), a panel of the open and resolved threads with
  their comments, replies, reactions, edits and deletes, a composer that
  comments on what the person selected or on the page, @mentions of the
  room's people and of `mentionable`, and the `:place` slot for a place
  in words. Its hook, `IsshoComments`, marks each open thread at its
  place over the page, where its component locates it (`commentMarkers`,
  `markSpot`, `locatePlace` in the `issho` package), opens a thread from
  its mark, scrolls the page to a thread's place, and shows times in the
  person's locale. Issho's theme styles them (`--issho-comments-*`,
  `--issho-mark-*`, `--issho-mention-background`).
- `Issho.Live.identity/1`: who the LiveView is in a room.
- Agents at work, seen and stopped: `Issho.Work`, an agent's task, its
  steps and how far it is, in its state in the room (`"task"`), with the
  `start_task`, `progress` and `finish_task` room tools; and Pause, Resume
  and Stop for the person it acts for, or whomever the policy allows
  `:interrupt` (a new policy action): `Issho.Live.interrupt/3`, the
  channel's `"interrupt"`, `room.interrupt()` in the browser,
  `Issho.Work.interrupt/5` from the server. A paused or stopped agent's
  transactions are refused (`{:error, {:interrupted, ...}}`), whole, and
  its next tool call that changes something says who and what to do. The
  events `"agent.started"`, `"agent.finished"`, `"agent.interrupted"` and
  `"agent.resumed"`. `Issho.Participant.interrupted/1`, `room/1`.
- `Issho.Components.agents/1` and its hook `IsshoAgents`: the agents at
  work in a room, live, with their tasks and steps, and Pause, Resume and
  Stop (`atWork` and `drawAgents` in the `issho` package).
- The policy's `:comment` action: a change to the comments asks for it,
  not `:write`, so a reader may comment when the policy allows it.
- Agents comment: the `list_threads`, `comment` and `resolve_thread` room
  tools, and `wait_for_events`'s `mentions_me` (`Issho.Agents.wait/6`'s
  `:mentions_me`) for the comments that mention them.
  `Issho.Participant.identity/1`.
- A document's spec may say the events its changes make happen
  (`:events`, a function of the operations and the context, run after
  each change is saved).

### Changed

- The map engine is version 2: a stored document of version 1 upgrades as
  it is.
- A session hears a document's changes before it takes its snapshot, so
  that none falls between them.

## [0.3.1] - 2026-10-22

### Fixed

- The Agents guide and `Issho.MCP` say to start `{Sake, ...}` in the
  supervision tree: without it, an MCP client that listens for changes
  failed with "Sake.Plug.Streams is not running".

## [0.3.0] - 2026-10-21

Agents that move as people do, and a page that is one live space across
its blocks. Kotoba 0.7, Hakushi 0.3 and Masu 0.5 run on it.

### Added

- One way for every component to join: `Issho.Join`, the `issho`
  option's keys (`instance`, `document`, `can`, `people`, `follow`,
  `on_behalf_of`, `claims`, and a component's own), checked, the same in
  Kotoba, Hakushi, Masu and yours.
- A component's own keys in a person's state go under its document
  (`"blocks"`): `Issho.Live.merge_block/3`,
  `Issho.Participant.aware_block/3`, `Issho.Motion.go/3`'s `:block`,
  `Issho.Awareness.block/2`, and
  `room.awareBlock` and `blockOf` in the browser. Issho owns a state's
  top-level keys.
- A room's events: `Issho.Event` and `Issho.Events` (subscribe, emit),
  with `"document.changed"` from every document and Issho's names
  reserved.
- `Issho.Identity.service/1`, the author of your server's own changes.
- A page with blocks of other rooms: a canvas shared in its own room,
  embedded in a document. Over a block of another room, the page's
  pointers share only that the pointer is in it, and draw no one there:
  the block's own room draws its people (the canvas, or that room's
  pointers). Following someone who goes into such a block keeps it on
  the screen and follows them in its room too, until they come out.
  `Issho.Components.pointers/1` says its room (`data-room`), so a block
  knows whether a layer of its own room draws its people.
- `Issho.Live.release/2` and `Issho.Live.leave/1`: a component that goes
  while its LiveView stays (an embed deleted from a document) releases
  its room, and the LiveView leaves it with its last component: its
  people see it go, its awareness clears, and its documents let it go.
  A component's hook says it went with the `"issho:release"` event
  (`room`, `component`), which Issho's hook takes.
  `Issho.Live.subscribe/3` takes `:on_release`, which runs when the
  component is released: for what it put in the session's awareness,
  which stays while the LiveView is in the room for its other components.
- One look for following, everywhere: `--issho-following-background`,
  `--issho-following-text` and `--issho-following-ring` restyle the
  "Following Ada" pill and the ring of Issho's people list and pointers,
  and of Kotoba's, Masu's and Hakushi's, which carry Issho's classes.
- A located place may say where in its box a pointer is (`x`, `y`,
  fractions of it): a grid's cell, which each page draws the pointer
  within at the same spot.
- Agents navigate: `Issho.Motion.navigate/2` and the `navigate` room
  tool take an agent to another page of the app, by its path; the pages
  of the people who follow it go there too (a live navigation when the
  page allows it). Only a path of the app goes, never another site.
  `look_around` says where each link goes (`href`) and which pages each
  person has open (`pages`); each browser reports its path.
- Browser tests of the page layer (`e2e/`, `mix test.e2e`), in Chromium,
  Firefox and WebKit on CI.
- `Issho.Motion`: an agent goes where it works as a hand would, in
  gestures (move, press, drag, release, click) to a place of a document
  or an element of the page (`data-issho-anchor`). Only where it goes is
  sent, once for each gesture; each browser draws the way there; the agent
  waits as long as that takes, within a tool call's time budget, and only
  when someone of the room sees it (a browser that says nothing, or a room
  without presence, counts as watching). `pause/4`, a moment before a
  change. `config :issho, Issho.Motion, travel:, flight:, step:, click:,
  budget:`.
- Each browser with Issho's pointers tells the room what it shows: the
  page in the foreground, the components on the screen, its person's
  motion, whom it follows, and the page's anchors.
- Room tools: `point` at an anchor, `click` an anchor; `look_around` lists
  the anchors of the people's pages.
- One pointer across the page's blocks: a component says where a place of
  its document is on the screen (`locate`) and which place is under a
  pointer (`point`), and a pointer over it is a place of its document,
  drawn where it is on each screen; an agent's pointer glides there in the
  time its gesture says, and rings where it clicks. At a place a component
  located, the pointer is the arrow only (the component names the agent).
- Following, a room's: the people list follows on a click (`follow={false}`
  for one that does not), with "Following Ada · Stop"; the page keeps the
  one followed on the screen; a link or a button with `data-issho-follow`
  they click is clicked for their followers. The state is the page's
  (`data-issho-following`, the `issho:following` event), so a block
  follows with or without Issho's script; `follow`, `following`,
  `onFollow` and `stopOnOwnWay` in the `issho` package.
  `follow_agents="on_behalf"` on the pointers follows an agent at work for
  the person as soon as it moves, unless they stopped following it.
- The person's motion is the app's to say: `motion` on the pointers,
  `setMotion` in the `issho` package, or `data-issho-motion` on the root
  element; else the browser's setting. `motion_switch/1`, an optional
  switch for it (the `IsshoMotion` hook).
- `Issho.Participant.key/1`.
- A guide for components built on Issho: [Building a component on
  Issho](guides/components.md).

### Changed

- A document's hook gets who made each change as `:by`, an
  `Issho.Identity` (a person, an agent and whom it acts for, a service),
  beside the `:author` key. `Issho.Authority.commit/3` takes an identity
  or a key, and `Issho.transact/4`'s `:author` an actor or a key.
- A document is what your policy's `document/2` says, whoever opens it
  first; a component's own spec (`Issho.Live.open/3`'s `:spec`) is used
  only for a document the policy does not know (`{:error, _}`). Before, a
  component's spec won over the policy, so the same document in two
  places (a canvas's page and an embed of it) was whatever the first to
  open it brought. See "One document, many places" in the Components
  guide.
- `Issho.Tools.run/3` runs each tool within its time budget
  (`Issho.Motion.within/2`).
- The people list's avatars of others are buttons (`.issho-person-follow`,
  `aria-pressed`).

### Fixed

- A form with shared components in it (`holdForm`) goes on a person's
  click when its components have nothing to send: it asked for the
  submit again while the browser still fired the one it stopped, which
  browsers ignore, and the form did not go.

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
