# Issho

![Issho — Collaboration for Phoenix](https://raw.githubusercontent.com/hattoriai/issho/main/media/banner.png)

Issho (一緒, "together") is collaboration for Phoenix: one engine for
people and agents working together live, under every component on a page.
Build apps like Notion, Figma or Linear, and bring any UI that follows the
Issho contract: Kotoba's rich text, Masu's grids, Hakushi's canvas, or
your own.

> **Status: in development, not released.** Issho ships when Kotoba, Masu
> and Hakushi run on it. What exists today is the server core and the
> browser client's core described below; the cursor overlay, following,
> the bindings and the agent protocols come next.

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
* **engines** for each kind of document, behind one boundary
  (`Issho.Engine`): the model is the binding's, everything else is Issho's;
* **presence** on `Phoenix.Presence`, and **awareness** (places,
  selections, locks) in batched frames: about 20 a second per session,
  whatever the size of the room;
* **agents in the room** from Elixir (`Issho.join_as/4`): the same
  presence, places, locks, transactions and policy as a browser;
* **a browser client** (`issho` on npm, built into the Hex package): a
  room per page shared by every component, its people and awareness, and
  shared documents whose changes show at once, wait while offline, and
  replay over the changes of others; documents open again after a
  reconnect, and only what the server does not have is sent;
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
