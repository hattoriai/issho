# Shared state

Most collaborative features are not a text editor or a canvas: they are a
few values and lists that people change together. A retro board's cards
and votes, a poll, a checklist, the order of a kanban's cards, whose turn
it is. `Issho.State` is that, without designing a document engine: a map
that the room's authority changes in one order, as a LiveView assign that
stays up to date, which agents change with one tool.

## The document

A shared state is a document of a room, with the map engine
(`Issho.Engine.Map`). Define it in your policy, with its initial content
from your database, and save it in its hook:

```elixir
def document(_who, "retro:" <> id) do
  retro = Retros.get!(id)

  {:ok,
   %{
     engine: Issho.Engine.Map,
     initial: retro.state,
     on_transaction: fn _ops, %{after: state, by: who} ->
       Retros.save(retro, state, who)
     end
   }}
end
```

The hook runs once for each change, before anyone sees it. It checks
what your app requires (a column's limit, who may move a card) and
answers `{:error, reason}` to refuse the change: the person who made it
gets the reason, and nobody else sees it.

## In a LiveView

```elixir
def mount(%{"id" => id}, _session, socket) do
  room = "retro:" <> id

  if connected?(socket),
    do: {:ok, _} = Issho.Live.join(MyApp.Issho, socket.assigns.current_user, room)

  {:ok, socket |> assign(:room, room) |> Issho.State.assign(:retro, room)}
end

def handle_event("add", %{"text" => text}, socket) do
  card = %{"id" => Ecto.UUID.generate(), "text" => text}
  :ok = Issho.State.change(socket, :retro, [Issho.State.insert(["cols", "todo"], card)])
  {:noreply, socket}
end

def handle_event("move", %{"id" => id, "to" => to, "after" => after_id}, socket) do
  op = Issho.State.move(["cols", "todo"], id, to: ["cols", to], after: after_id)
  :ok = Issho.State.change(socket, :retro, [op])
  {:noreply, socket}
end
```

```heex
<div :for={col <- ["todo", "doing", "done"]}>
  <div :for={card <- Issho.State.get(@retro, ["cols", col]) || []}>{card["text"]}</div>
</div>
```

`@retro` changes when the authority accepts a change, from this LiveView
or anyone's, in the same order everywhere. In the static render, before
the LiveView is in the room, it is `%{}` (or `:default`).

## Operations

| Operation | |
| --- | --- |
| `set(path, value)` | the value at a path, making the maps on the way |
| `delete(path)` | a key, or an item of a list |
| `increment(path, by)` | adds to a number; votes and counters add up |
| `insert(path, item, after: id)` | an item (a map with an `"id"`) in a list, `after:`, `before:` or `at: :start` |
| `move(path, id, to: path, after: id)` | an item within its list, or to another |
| `remove(path, id)` | an item of a list |

A path goes through maps by key and through lists by an item's id:
`["cols", "todo", card_id, "votes"]`. Changes made at once merge: two
people who add a card both have theirs; a card placed after one that was
just deleted goes to the end; a vote for a card that was just deleted
does nothing.

Several operations given together are one change: all apply, or none.

## Agents

Agents change a shared state with the `update_state` room tool, in the
same operations, and read it with `read_document`. Your server changes it
with `Issho.transact/4`. Each change is in your hook with who made it
(`:by`), whoever made it.

## In the browser

A component that renders a state in the browser opens it like any
document (`room.open(id)`): `mapEngine` is the engine's twin, held to the
same cases as the server's.
