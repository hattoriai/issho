# Agents

In an Issho room, an agent is someone: people see it in the list of who is
here, see where it points and what it selects, and see its changes land as
it makes them, merged with their own. It acts under your policy, as anyone
in a room does.

There are three ways in, for three kinds of agent.

## From your app: `Issho.join_as/4`

An agent that runs in your app (a job, a model you call, a bot) joins a
room as a participant, for as long as it works:

```elixir
{:ok, claude} =
  Issho.join_as(MyApp.Issho, %{id: "agent:summarizer", name: "Summarizer", kind: :agent}, "board:42")

{:ok, _snapshot} = Issho.Participant.open(claude, "board:42")
Issho.Participant.aware(claude, %{"status" => "Summarizing"})
{:ok, _receipt} = Issho.Participant.transact(claude, "board:42", ops)
Issho.Participant.leave(claude)
```

The participant is linked to the process that joins: it leaves when that
process ends.

## From your app, across calls: `Issho.Agents`

A front end with no lasting connection (a webhook, a chat bot answering
one message at a time) keeps its agent in the room between calls with
`Issho.Agents`: the agent joins on the first call, stays where it last
pointed, and leaves after `:idle` milliseconds with nothing to do (ten
minutes), or when told.

```elixir
{:ok, participant} = Issho.Agents.join(MyApp.Issho, agent, "board:42", idle: 300_000)
```

## Over MCP: `Issho.MCP`

An agent outside your app (Claude Code, Claude Desktop, any MCP client)
connects to your app's MCP endpoint. `Issho.MCP` is a
[Sake](https://hex.pm/packages/sake) server of room tools:

| Tool | What it does |
|---|---|
| `join_room` | joins a room; gives who is here and where |
| `look_around` | who is here now, and where each is |
| `read_document` | a document's engine, revision and state |
| `point` | shows the others a place, in the document's terms |
| `set_status` | a few words the others see beside the agent's name |
| `change_document` | the engine's own operations, as one transaction |
| `leave_room` | leaves the room |

The components bring their own tools, in their own terms:
`Kotoba.Issho.MCP` (read, select, type, format, link, copy and paste in
a rich text) and `Hakushi.Issho.MCP` (read, point, add, drag, connect a
canvas). Serve them together, as your app serves MCP:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  mount Issho.MCP
  mount Kotoba.Issho.MCP
  mount Hakushi.Issho.MCP
end
```

```elixir
# In your router, with any of Sake's options: its OAuth, your own
# authorization server, or none.
import Sake.Router
sake_endpoint "/mcp", server: MyApp.MCP
```

```elixir
# config/config.exs
config :issho, Issho.MCP, instance: MyApp.Issho
```

Issho does not choose how agents connect: HTTP or stdio, Sake's
authorization, yours or none (in development), its own endpoint or
mounted in yours. It asks one thing: who a caller is in the rooms.

## Who the agent is

The agent a call acts as comes from the call. Without a setting of yours,
it is named for its MCP client ("Claude Code") and acts on behalf of the
principal your endpoint signed in, when that principal is an
`Issho.Actor`, or as itself when there is none.

Say otherwise with `:agent`, a function of the call's `Sake.Context`
that gives the actor and its options:

```elixir
config :issho, Issho.MCP, instance: MyApp.Issho, agent: {MyApp.Collaboration, :agent}
```

```elixir
# A person's own assistant, on their behalf: the policy lets it do what
# the person may.
def agent(%Sake.Context{scope: %MyApp.User{} = user}),
  do: {%{id: "assistant:#{user.id}", name: "Assistant", kind: :agent}, on_behalf_of: user}

# A service (Sake's client credentials grant), acting as itself.
def agent(%Sake.Context{scope: %MyApp.Service{} = service}),
  do: {%{id: "service:#{service.id}", name: service.name, kind: :service}, []}
```

An app can have several at once: on one endpoint, deciding from the call,
or on several endpoints, each with its own settings, set by a plug before
it:

```elixir
pipeline :bot_mcp do
  plug Issho.MCP.Setup, agent: {MyApp.Collaboration, :bot}
end
```

Your policy sees the agent as it sees anyone: an `Issho.Identity` of
`kind: :agent` (or `:service`), with `on_behalf_of` the person when there
is one. Let agents in where you want them, and only there.

## Trying it

Hakushi's and Kotoba's development apps serve their tools at `/mcp`,
with no authorization. With `mix dev` running and a canvas or a notebook
open in a browser:

```
claude mcp add --transport http hakushi-dev http://localhost:4099/mcp
```

then ask Claude Code to work on the canvas (`atelier:schema`), and watch
its pointer in the browser.
