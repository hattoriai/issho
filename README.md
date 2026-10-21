# Issho

![Issho — Collaboration for Phoenix](https://raw.githubusercontent.com/hattoriai/issho/main/media/banner.png)

Issho (一緒, "together") is collaboration for Phoenix: one engine for
people and agents working together live, under every component on a page.
Build apps like Notion, Figma or Linear, and bring any UI that follows the
Issho contract: Kotoba's rich text, Masu's grids, Hakushi's canvas, or
your own.

> **Status: early release.** Rooms, documents, LiveView sessions, grants,
> the browser client, the people list and theme, the page's pointers, undo
> across a page, agents however they connect (MCP, your app's own model),
> and the bindings of Kotoba, Hakushi and Masu are here. Following across
> pages and the installer come next; before 1.0, a minor version may
> change the API.

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

* **Following across pages.** A room is a page today. One level above it
  (an app's or a workspace's room, joined on every page) will hold where
  each person is, their route and their place, so that following someone
  (a person, or an agent to watch it work) navigates with them, through
  LiveView's navigation, and each component reveals their place in the
  new page: the paragraph, the node.
* **Components inside components.** A rich text editor in a canvas node,
  its body a document of the canvas's room (`board:42/n7/body`): one
  people list, a cursor that goes from the canvas into the text, an agent
  that drags the note and writes in it (hattoriai/hakushi#2).
* **Live embeds, by reference.** A component shown, live, inside another:
  a canvas or a grid in a rich text (hattoriai/kotoba#53), small, with
  its people and their cursors, and full size when opened. The reference
  is a room and a document, joined as a viewer:
  * on another page of the app: rooms are not pages, and a read grant
    for the referenced room is all it takes;
  * in another app of the same BEAM cluster: the apps share Issho's
    PubSub and registry, so the room's authority is found and its
    changes reach every node, as today;
  * in an app outside the cluster: a remote grant. The owning app signs a
    read grant for its room, and the browser opens the room on the owning
    app's socket, across origins. The transport already takes a socket
    URL and a token; what is to come is issuing grants from app to app,
    and their policy.
* **Settings for a page or a room.** What a page allows its components
  (no undo in this space, for example), carried in the room's signed
  grant, so every component follows it. Undo stays a choice of the
  interface: an undo is a change like any other, and what a room must
  refuse (deleting, changing what was published) belongs in its policy
  or its document's checks on the server.
* **An installer**, and a demo app of many components.

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
