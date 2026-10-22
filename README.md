# Issho

![Issho — Collaboration for Phoenix](https://raw.githubusercontent.com/hattoriai/issho/main/media/banner.png)

Issho (一緒, "together") is collaboration for Phoenix: one engine for
people and agents working together live, under every component on a page.
Build apps like Notion, Figma or Linear, and bring any UI that follows the
Issho contract: Kotoba's rich text, Masu's grids, Hakushi's canvas, or
your own.

> **Status: early release.** Rooms, documents, LiveView sessions, grants,
> the browser client, the people list and theme, the page's pointers and
> following, agents however they connect (MCP, your app's own model) and
> how they move, undo across a page, blocks of other rooms in a page (live
> embeds), and the bindings of Kotoba, Hakushi and Masu are here. Comments
> and the installer come next (see the roadmap); before 1.0, a minor
> version may change the API.

Live collaboration in the Hattori libraries is Issho's: Kotoba's shared
editing (from 0.6), Masu's grids' people (from 0.4) and Hakushi's
canvases. Each library works on its own without it; with it, a page of
them has one connection, one list of people, one policy, and agents that
work across all of them.

## Installation

```elixir
def deps do
  [
    {:issho, "~> 0.2"}
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

### Collaboration features

* **Comments and threads.** A thread on a place of any component, as
  each already names its places (`Issho.Place`): a range of text, a
  canvas's node, a grid's cell. Replies, @mentions of people and agents,
  reactions, resolve and reopen, attachments; a composer, a thread and
  an all-comments panel, and each component marking where its threads
  are. A commenter between a reader and a writer, in the policy. An agent
  mentioned in a thread answers there, and does what it asks.
* **Notifications and an inbox.** Mentions, replies, assignments and an
  app's own kinds, unread until seen, live in the page and batched to
  email through the app's own mailer. Phoenix makes the plumbing easy;
  what Issho can offer out of the box is still to decide (an inbox
  component, a schema, the events comments emit).
* **Version history (to explore).** The authority keeps every accepted
  transaction, and replays a document at an earlier revision. What it
  could become: named versions, a document as it was, restore, and each
  component's diff (text, canvas, grid), beyond Kotoba's own undo
  history.
* **A chat for agents (maybe).** Agents are participants of the room,
  with presence, motion and tools; a chat component of the page, in its
  room, could be where people ask them, beside the components they work
  in.

### The framework

* **Room events.** Events at Issho's level that components and the app
  act on: a person joins or leaves, a document changes, a thread is
  created, an agent finishes, and an app's own (a reaction, a toast).
  Broadcast to the room's components in the browser, given to the app on
  the server (callbacks and `:telemetry`), and to agents: an agent that
  waits on the room's events (someone selects text and asks it, a row
  changes, a card lands on a frame) answers by itself, through a tool
  that waits and MCP notifications through Sake.
* **Rooms from the server.** The rooms running, who is in each, and
  their documents, read and changed from your code, for an admin page, a
  job or a test.
* **Dev tools and a LiveDashboard page.** Rooms, documents, people,
  pending queues and transactions, in the browser while you build and in
  LiveDashboard in production.
* **Following across the app.** A room is a page today: following takes
  people along the links and navigations of the one they follow
  (`data-issho-follow`, `Issho.Motion.navigate/2`) within a room. One
  level above (an app's or a workspace's room, joined on every page)
  would hold where each person is, so that following reaches someone on
  any page, and each component of the new page reveals their place in
  it: the paragraph, the node.
* **Components inside components.** A canvas or a grid embedded in a
  text works today, in its own room. The other way is to come: a rich
  text in a canvas's node, its body a document of the canvas's room
  (`board:42/n7/body`), with one people list, a cursor that goes from the
  canvas into the text, and an agent that drags the note and writes in
  it (hattoriai/hakushi#2).
* **Embeds from another app.** Embedding a block of another page of the
  same app works today (a read grant for its room). For an app outside
  the cluster: a remote grant, signed by the owning app for its room, and
  the browser opens the room on that app's socket, across origins. The
  transport already takes a socket URL and a token; what is to come is
  issuing grants from app to app, and their policy.
* **Settings for a page or a room.** What a page allows its components
  (no undo in this space, for example), carried in the room's signed
  grant, so every component follows it. Undo stays a choice of the
  interface: what a room must refuse belongs in its policy or its
  document's checks on the server.
* **Permissions (to think about).** Roles (viewer, commenter, editor)
  and access per room would save every app writing its policy from
  nothing, but apps have their own permission systems: what Issho offers
  must fit them, not replace them.

### Getting started

* **An installer** (`mix issho.install`) and generators, a guide from
  nothing to a collaborative page in minutes, and example apps
  (Notebook, the demo of Kotoba, Hakushi and Masu on Issho).

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
