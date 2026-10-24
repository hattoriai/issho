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

The next step is to let developers define an application capability once:
people use it through the UI, agents use it through tools or visible
interaction, and everyone works on the same authorized live state.

The [roadmap tracking issue](https://github.com/hattoriai/issho/issues/48)
keeps the existing priorities, proposals, dependencies, and acceptance
criteria. The direction is:

* **Open the component contract to every author.** Stabilize and test
  the contract, add generators and a reference component, and make
  ordinary LiveView features collaborative without a custom engine.
* **Share actions between people and agents.** Add semantic observations,
  revision checks, and visible execution with human takeover, under the
  application's policy.
* **Make work reviewable and recoverable.** Add proposals people can
  inspect and accept, durable agent runs, and storage and event delivery
  that support recovery after failure.
* **Bring the same collaboration to more surfaces.** Export components
  through MCP Apps to supported AI hosts, then compose workspaces from
  registered components and typed bindings.
* **Prove the behavior.** Extend component conformance with replay and
  failure simulation; measure backpressure, failover, and scaling with
  reproducible workloads.

These are planned capabilities, not a release schedule. Getting started,
developer tools, scoped agent access, and the existing comments, history,
and following improvements remain part of the linked plan.

Issho runs in your Phoenix application. Your data, permissions, behavior,
and presentation remain yours; Issho owns the collaboration semantics.

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
