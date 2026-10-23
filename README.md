# Issho

![Issho — Collaboration for Phoenix](https://raw.githubusercontent.com/hattoriai/issho/main/media/banner.png)

Issho (一緒, "together") is an open-source collaboration toolkit for
Phoenix that makes it easier to build applications where people and AI
agents work together in real time.

It provides the shared foundations (rooms, participants, presence,
authorization, documents, synchronization and agent participation), so
that developers can focus on their applications instead of rebuilding
collaboration features. Bring your own components, your own agents and
your own application logic.

**Issho owns collaboration semantics. Applications and component
libraries own their behavior and presentation.**

> **Status: early release.** Rooms, documents, LiveView sessions, grants,
> the browser client, the people list and theme, the page's pointers and
> following, agents however they connect (MCP, your app's own model) and
> how they move, undo across a page, blocks of other rooms in a page (live
> embeds), the room's events, shared state without an engine, comments
> and threads on any component, agents seen at work and stopped, an
> agent's inbox, streams of a room, and the bindings of Kotoba, Hakushi
> and Masu are here. Before 1.0, a minor
> version may change the API; see the roadmap for what comes next.

Live collaboration in the Hattori libraries is Issho's: Kotoba's shared
editing (from 0.6), Masu's grids' people (from 0.4) and Hakushi's
canvases. Each library works on its own without it; with it, a page of
them has one connection, one list of people, one policy, and agents that
work across all of them.

## Installation

```elixir
def deps do
  [
    {:issho, "~> 0.4"}
  ]
end
```

Issho needs Elixir 1.18 or later, Phoenix 1.7.14 or later and, for
`Issho.Live`, Phoenix LiveView 1.1 or later.

It gives your app:

* **rooms** with your own authorization: one `authorize/3` asked on
  join, on every message from a browser, and before each change goes out
  to one, so that a person whose access you take away stops receiving
  changes; `Issho.revoke/3` takes an actor out of a room now, on every
  node;
* **actors of any kind**: users, admins, guests, services and agents,
  through the `Issho.Actor` protocol, with no user model of Issho's;
* **documents** with one authority each across a cluster, which orders
  every change, applies it once (a retry gets its receipt), saves it with
  your store, and only then confirms and broadcasts it; any revision of
  an epoch can be read again, for forms that publish exactly what a person
  saw;
* **your tables as the truth** when you want them: a document's
  `:on_transaction` hook runs once for each accepted change, before
  anyone sees it, to save it (or refuse it), and a document with
  `store: :none` starts from your data each time it opens;
* **engines** for each kind of document, behind one boundary
  (`Issho.Engine`): the model is the binding's, everything else is Issho's;
* **presence** on `Phoenix.Presence`, and **awareness** (places,
  selections, locks) in batched frames: about 20 a second per session,
  whatever the size of the room;
* **LiveViews in the room** (`Issho.Live`): a LiveView is a session like
  a browser's, and the room's changes, people and awareness reach its
  components;
* **agents in the room**, however they reach your app: your app's own
  model through an API (`Issho.Tools`), MCP clients (`Issho.MCP`, with
  [Sake](https://hex.pm/packages/sake)), your code (`Issho.join_as/4`),
  or what comes next. The same presence, places, transactions and policy
  as a person, a person's agent on their behalf or your app's bot as
  itself, and the same tools (`Issho.Tool`): Issho's, and the
  components' own (`Kotoba.Issho.tools/0`, `Hakushi.Issho.tools/0`), so
  an agent selects, types, drags and connects as a person does, and the
  people see it (see the agents guide);
* **events** of the room (`Issho.Events`): who comes and goes, what
  someone selects, each document's changes, comments, agents' tasks, and
  your app's own, for your code, a LiveView's components, `:telemetry`,
  and agents that wait for them (`wait_for_events`);
* **shared state without an engine** (`Issho.State`): a map, with lists of
  items by id that merge concurrent adds and moves, as a LiveView assign
  that stays up to date; a retro, a poll, a kanban's order in an
  afternoon, which agents change with one tool;
* **comments** (`Issho.Comments`) on a place of any component (a range of
  text, a node, a cell) or the page: replies, reactions, @mentions of
  people and agents, resolve and reopen, each held to its writer's signed
  identity, a panel (`Issho.Components.comments/1`) and marks drawn at
  each thread's place by the component's own `locate`; a commenter
  between a reader and a writer (the policy's `:comment`);
* **agents seen at work, and stopped** (`Issho.Work`): an agent's task
  and its steps as it goes (`Issho.Components.agents/1`), and Pause,
  Resume and Stop for the person it works for, between whole changes;
  your app's own agent's work (`Issho.Agents.run/5`) is stopped at once,
  wherever it is, and its crash is said in the room;
* **an inbox** (`Issho.Inbox`) of what was said to someone while away: a
  comment that mentions an agent that is not connected waits for it (the
  `inbox` tool, `issho://inbox` over MCP), and your app can wake it
  (`:on_mention`);
* **streams of a room** (`Issho.Streams`): output a process writes a
  piece at a time (a model's answer, an agent's report, a log), for a
  person or the room, that people see as it comes and find again where
  it got to when they come back, from another page, tab or node;
* **one page, one room**: the components of a page share its connection,
  its people (`Issho.Components.people/1`), its grant from the LiveView
  (`Issho.Live.grant/4`, renewed by Issho), its form barrier (`holdForm`)
  and its undo (`pageHistory`), so a cursor goes from one component to
  another;
* **a browser client**, built into the Hex package (`import ... from
  "issho"`): a room per page shared by every component, its people and
  awareness, and shared documents whose changes show at once, wait while
  offline (kept across a reload of the tab), and replay over the changes
  of others; after a reconnect, only what the server does not have is
  sent;
* engines in pairs, Elixir and TypeScript, held to one shared corpus of
  cases (`test/corpus`), so the browser and the server never disagree;
* `Issho.Test`, to start an isolated instance in a test and check that an
  engine replays.

## A sketch

```elixir
# In your supervision tree, after the PubSub:
{Issho,
 name: MyApp.Issho,
 pubsub: MyApp.PubSub,
 endpoint: MyAppWeb.Endpoint,
 policy: MyApp.Collaboration,
 store: {MyApp.CollabStore, MyApp.Repo}}
```

```elixir
defmodule MyApp.Collaboration do
  @behaviour Issho.Policy

  @impl true
  def authorize(who, "board:" <> id, action),
    do: if(MyApp.Boards.allowed?(who.claims["user_id"], id, action), do: :ok, else: {:error, :forbidden})

  @impl true
  def document(_who, "board:" <> id),
    do: {:ok, %{engine: Issho.Engine.Map, initial: MyApp.Boards.content(id)}}
end
```

```elixir
# A channel on a socket of your endpoint:
defmodule MyAppWeb.IsshoChannel do
  use Issho.Channel, instance: MyApp.Issho
end

# A LiveView signs the browser's join token:
token = Issho.Token.sign(MyApp.Issho, current_user, "board:42",
  can: :write, claims: %{"user_id" => current_user.id})
```

```heex
<%!-- With `import Issho.Components` in your app's html_helpers: the room's
     people, everyone's pointer over the page, the agents at work, and
     the room's comments (in a LiveView that joined the room). --%>
<.people id="people" grant={@grant} />
<.pointers id="pointers" grant={@grant} />
<.agents id="agents" grant={@grant} />
<.comments id="comments" room="board:42" />
```

```elixir
# An agent joins the same room:
{:ok, claude} = Issho.join_as(MyApp.Issho, agent, "board:42", on_behalf_of: current_user)
{:ok, _doc} = Issho.Participant.open(claude, "board:42")
{:ok, _receipt} = Issho.Participant.transact(claude, "board:42", ops)
```

## In the browser

```js
import { joinRoom } from "issho"

const room = await joinRoom("board:42", { token, self: "user:ada" })
const doc = await room.open("board:42")

doc.on((event) => event.type === "change" && render(event.state))
doc.change([{ op: "set", path: ["title"], value: "Q3 plan" }])

room.aware({ place: { doc: "board:42", at: { path: ["title"] } } })
room.awareness.on((peers) => drawCursors(peers))
room.presence.on(() => drawPeople(room.presence.others))
```

## Roadmap

Three priorities first, because they prove Issho's promise most
directly: components from anyone working together on one page, ordinary
Phoenix developers building collaborative features without designing a
document engine, and agents as participants everywhere.

### 1. The component contract, for every author

Kotoba, Masu and Hakushi are built on Issho, but another author should
not have to copy their patterns to do the same. The contract between a
component and Issho (its engine and places, `locate` and `point`,
following, motion, agents' tools, releasing a room, a block of another
room) becomes the center:

* **A stable, versioned contract**, documented on its own (the
  Components guide is its start), that Issho keeps across releases.
* **A conformance kit**: tests a component author runs against their
  component (`Issho.Test` for engines grows into checks for places,
  locating, following and tools, in Elixir and in the browser).
* **A generator and a reference component**: `mix issho.gen.component`
  for the binding, the hook and the tools, and a small component outside
  the Hattori libraries that shows the whole contract.
* **Components inside components.** A canvas or a grid embedded in a
  text works today, each in its own room. The other way is to come: a
  rich text in a canvas's node, its body a document of the canvas's room
  (`board:42/n7/body`), with one people list, a cursor that goes from the
  canvas into the text, and an agent that drags the note and writes in
  it (hattoriai/hakushi#2).

### 2. Developer experience

An ordinary Phoenix developer should build a collaborative checklist or
kanban board in an afternoon. Shared state without an engine
(`Issho.State`) is here; what comes next:

* **Getting started.** An installer (`mix issho.install`) and
  generators, a guide from nothing to a collaborative page in minutes,
  and example apps (Notebook, the demo of Kotoba, Hakushi and Masu on
  Issho).
* **Rooms from the server.** The rooms running, who is in each, and
  their documents, read and changed from your code, for an admin page, a
  job or a test.
* **Dev tools and a LiveDashboard page.** Rooms, documents, people,
  pending queues and transactions, in the browser while you build and in
  LiveDashboard in production.

### 3. Agents through everything

Agents are participants of every room, with presence, places, motion and
tools, under the same policy as people. The room's events and agents
that wait for them, tasks people see, and Pause, Resume and Stop are
here. What comes next:

* **Scoped tools.** An agent gets the tools, rooms and documents it is
  given, no more: per agent, per room and per person it acts for.
* **Attribution, carried through.** Every change records who made it (a
  person, an agent, and for whom), in the hook and the events today;
  next, in history and in the components' own views.
* **Events over MCP.** An agent that is not in a tool call hears of a
  mention or a change (MCP notifications), not only while it waits.

### Next, on that foundation

* **Comments, further.** Threads that follow their text as it is edited
  (each component places its threads again), attachments, an inbox of
  one's mentions across rooms.
* **Version history (to explore).** The authority keeps every accepted
  transaction and replays a document at an earlier revision. What it
  could become: named versions, a document as it was, restore, and each
  component's diff.
* **Following across the app.** Following takes people along the links
  and navigations of the one they follow within a room
  (`data-issho-follow`, `Issho.Motion.navigate/2`). An app's or a
  workspace's room, joined on every page, would hold where each person
  is, so that following reaches someone on any page.
* **Settings for a page or a room.** What a page allows its components
  (no undo in this space, for example), carried in the room's signed
  grant, so every component follows it.

### Later, on purpose

Useful, but they do not prove the central promise as directly as
components working together do, and they are easy to get wrong early:

* **A universal notification system.** The events comments and agents
  emit are here; an app's inbox and emails are a few Phoenix pieces on
  top of them.
* **An opinionated roles framework.** Apps have their own permission
  systems; Issho's policy fits them, with `:comment` and `:interrupt`
  between a reader and a writer.
* **Federation across applications.** Embeds of another page of the same
  app work today; signing grants from one app to another comes later.
* **A built-in agent chat.** Agents act in the components people use,
  and answer in comments; an app adds a chat of its own if it wants one.

### What stays Issho's

The server decides every change, and your policy and checks always win.
Issho is LiveView's: components, not a hosted SDK. It runs in your app,
and your database is the truth. Agents are participants of the room,
with presence, motion and tools, as people are.

## Development

```sh
mix deps.get
npm ci --prefix assets
mix test        # includes the end-to-end test of the client on a real endpoint
mix test.js     # the browser client's unit tests
mix precommit   # compile with warnings as errors, format, credo, test
MIX_ENV=dev mix issho.build   # the bundles, into priv/static
```

## License

MIT. See [LICENSE](https://github.com/hattoriai/issho/blob/main/LICENSE).
