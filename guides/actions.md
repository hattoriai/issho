# Actions

A button that checks an item, a keyboard command that archives a card,
an agent asked to "mark the draft done": the same thing, done by
different hands. An action (`Issho.Action`) is that thing, once, on the
server. A person's LiveView, your Elixir code and an agent's tool all run
it, under the same policy and the same rules of your app, and each is
told the same outcome.

This is Issho's principle for agents: they do what people do, by the way
people do it. An agent has no tool of its own that checks the item its
own way, and no click that only looks like the item was checked.

## The smallest action

An action needs no document, no engine and no component: an ordinary
LiveView with a button is enough.

```elixir
defmodule MyApp.Actions.CheckItem do
  use Issho.Action,
    name: "check_item",
    description: "Checks or unchecks an item of a checklist."

  arg :list, :string, required: true
  arg :item, :string, required: true
  arg :done, :boolean, required: true

  @impl Issho.Action
  def target(%{list: list}), do: "checklist:#{list}"

  @impl Issho.Action
  def run(%{item: item, done: done}, invocation) do
    MyApp.Checklists.check(item, done, by: invocation.by)
  end
end
```

`target/1` is the action's room: where the policy is asked (`can`, which
is `:write` unless the action says), where the room hears it done, and
where an agent is paused or not. `run/2` is your change, as the
invocation's `by` (an `Issho.Identity`: the person, or the agent and the
person it acts for).

## A person

The LiveView is in the room (`Issho.Live.join/4`):

```elixir
def handle_event("check", %{"item" => item, "done" => done}, socket) do
  args = %{list: socket.assigns.list.id, item: item, done: done == "true"}

  case Issho.Live.act(MyApp.Actions.CheckItem, args) do
    {:ok, _receipt} ->
      {:noreply, socket}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, Issho.Action.message(reason))}
  end
end
```

## An agent

The action is a tool. Give it with the others:

```elixir
tools = Issho.Tools.room() ++ [MyApp.Actions.CheckItem]
```

or serve it over MCP (`Issho.MCP`'s `:tools`). The agent joins the
action's room when it runs it, so the people there see it, and can pause
it. Its tool takes one more argument, `invocation_id`, for retries.

## What it checks

In this order:

1. the arguments, against what the action declares;
2. the room's policy, and the action's `authorize/2`, for what the
   policy cannot say (the item is in this list, it is not archived);
3. the invocation's id: a retry with the same id and the same arguments
   gives the first receipt (`replayed: true`) and does nothing again; the
   same id for other arguments, another action or someone else is
   refused (`:id_reused`); one still running is `:in_progress`;
4. the agent's pause or stop, right before the change
   (`Issho.Work.guard/2`).

Done, it gives `{:ok, %Issho.Action.Receipt{}}`, and the room hears
`"action.done"`, by whoever did it. Refused, stale, paused or failed, it
gives `{:error, reason}`, never a receipt, and the same id may run again.

`Issho.Action.allowed/5` makes the same checks without running anything:
for a button's disabled state, and its reason.

## A component's action

A component's commands are actions too. Hakushi's "connect these two
cards" is one action: the canvas's own gesture (a person drawing the
edge) and the agent's `connect_nodes` both run it. Its change is a
transaction of the component's document, made as whoever runs it, under
the room's policy:

```elixir
@impl Issho.Action
def run(%{canvas: canvas} = args, invocation) do
  Issho.Action.transact(invocation, canvas, [connect(args)])
end
```

`Issho.Action.read/2` reads the document first, to check what the action
changes (the cards are there), and `Issho.Action.transact/4` makes the
change, each through the entry point's way to the room: the person's LiveView session (`Issho.Live.act/3`), or the agent's
participant. Your code, with neither, gets `{:error, :not_in_room}`:
join first (`Issho.join_as/4`) and give `:participant`.

Typing and dragging need no action: a keystroke of a person and an
agent's change of the same text are already one thing, a transaction of
the document under its policy. An action is for a command: something
with a name, rules of its own and an outcome to tell.

## Seen as it is done

An agent's action can be seen as a person's is. Its `gesture/2` moves the
agent's pointer to where the action is, with `Issho.Motion`, before the
change:

```elixir
@impl Issho.Action
def gesture(%{source: source, target: target}, invocation) do
  with :ok <- Issho.Motion.go(invocation.participant, place(source)),
       do: Issho.Motion.go(invocation.participant, place(target))
end
```

The pause is checked after the gesture, right before the change: an
agent paused on its way changes nothing, and is told so, never "done".
`visible: false` (`Issho.Action.invoke/5`) makes the same change at once,
with no gesture. A person's action has none: they made their own.

## What an agent may do here

`list_actions` (`Issho.Tools`) gives an agent the actions among its tools,
each allowed in the room or not, and why not: the policy's `can`, and the
action's `offer/2` when it has one (the room has no canvas; only the
page's people may). `Issho.Action.offered/4` is the same list, for a page
that shows a person what they may do.

## Preconditions

A change that depends on what its author saw says so in its arguments:
an Issho document's version (`if_revision`, `Issho.Version`), or your
record's own (`updated_at`, a lock version). `run/2` refuses a stale one
with `{:error, reason}`, in words the person or the model reads.

## Retries

Receipts are kept in the memory of the node that ran them, for
`:action_keep` milliseconds (ten minutes): a retry that reaches another
node, or comes after, runs again. Make `run/2` safe to run twice where
that matters (an upsert, a unique key), until receipts are durable.

## What it is not

An action runs only your code. It never runs a LiveView's events, the
DOM's clicks, or code a model wrote. What can be undone is your app's to
say, with an action of its own.
