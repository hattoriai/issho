# Agents

In an Issho room, an agent is someone: people see it in the list of who is
here, see where it points and what it selects, and see its changes land as
it makes them, merged with their own. It acts under your policy, as anyone
in a room does.

How the agent reaches your app is yours to choose, and Issho does not
depend on it: your app's own model through an API, an MCP client, a job,
a bot, or whatever comes next. Each way in only says who the agent is;
the rooms, the tools and the policy are the same.

## Who an agent is

An agent is an `Issho.Actor` of `kind: :agent` (or `:service`, for your
app itself), with, when it acts for someone, `on_behalf_of` that person,
and `claims` your policy reads:

```elixir
# A person's own assistant, on their behalf: let it do what the person may.
assistant = %{id: "assistant:#{user.id}", name: "Assistant", kind: :agent}

# Your app's bot, acting as itself, for no one.
bot = %{id: "bot:digest", name: "Digest", kind: :service}
```

Both can be in one room at once. Your policy's `authorize/3` sees an
`Issho.Identity` with the kind, the key, `on_behalf_of` and the claims:
let agents in where you want them, and only there.

## Tools

What an agent can do is a list of tools (`Issho.Tool`): Issho's for rooms
(`Issho.Tools.room/0`: join, look around, read, point, say what it does,
change, wait for what happens, leave), the components' in their own terms
(`Kotoba.Issho.tools/0`: select, type, format, link, copy and paste in a
rich text; `Hakushi.Issho.tools/0`: point, add, drag, connect on a
canvas), and yours. A tool runs as the agent of an `Issho.Tool.Context`,
which joins the rooms it works in and stays between calls, until it
leaves or has been idle for a while (`Issho.Agents`).

## Waiting for people

An agent in a room hears what happens in it (`Issho.Event`): someone
comes or goes, selects something, changes a document, writes a comment,
or an event of your app's. It keeps the last hundred since it last asked,
and `wait_for_events` gives them, or waits up to a minute for the next:

```text
wait_for_events {"room": "board:42", "names": ["selection.changed", "comment.*"], "seconds": 30}
```

So an agent can work with people instead of only for them: wait until
Ada selects a paragraph, then rewrite it; wait until a card lands on a
frame, then file it. From Elixir, `Issho.Agents.wait/5` is the same, and
a participant that joins with `events: true` receives the room's events
as messages.

## Your app's own model

Give the model the tools' definitions, and run the tools it uses as its
agent:

```elixir
tools = Issho.Tools.room() ++ Kotoba.Issho.tools()
ctx = Issho.Tool.Context.new(MyApp.Issho, assistant, on_behalf_of: current_user)

# The tools of a request to the model's API: name, description, input_schema.
definitions = Issho.Tools.schemas(tools)

# For each tool use in its answer, the result to send back:
{:ok, result} = Issho.Tools.call(tools, tool_use["name"], tool_use["input"], ctx)
```

An error comes back as `{:error, text}`, in words the model reads ("The
text "Q3" is not in the document."): send it back as the tool's result,
marked as an error, and the model tries again.

## MCP clients

Serve the same tools to MCP clients (Claude Code, Claude Desktop, any
other) with `Issho.MCP`, a [Sake](https://hex.pm/packages/sake) server.
Add Sake to your dependencies:

```elixir
{:sake, "~> 0.4"}
```

```elixir
defmodule MyApp.MCP do
  use Issho.MCP,
    name: "my-app",
    version: "1.0.0",
    tools: Issho.Tools.room() ++ Kotoba.Issho.tools() ++ Hakushi.Issho.tools()
end
```

```elixir
# In your application's supervision tree, before the endpoint: Sake's
# streams (a client's `subscriptions/listen`) and tasks run there.
{Sake, secret_key_base: {MyAppWeb.Endpoint, :config, [:secret_key_base]}, pubsub: MyApp.PubSub}
```

```elixir
# In your router, with any of Sake's options: its OAuth, your own
# authorization server, or none.
import Sake.Router
sake_endpoint "/mcp", server: MyApp.MCP
```

Without `{Sake, ...}`, tool calls work but the first client that listens
for changes fails with "Sake.Plug.Streams is not running". Claude Code
does that as soon as it connects.

```elixir
# config/config.exs
config :issho, Issho.MCP, instance: MyApp.Issho
```

Serve it as you serve MCP: HTTP or stdio, on its own endpoint or mounted
in your own server. Who a caller is comes from the call: without a
setting, it is an agent named for its client ("Claude Code"), on behalf
of the principal your endpoint signed in when that is an `Issho.Actor`.
Say otherwise with a function of the call (`Issho.MCP.Session`), or per
endpoint (`Issho.MCP.Setup`), for example a person's assistant on one
endpoint and your app's bot on another.

## From your code

A job or a process of your app joins a room as a participant, for as
long as it works:

```elixir
{:ok, agent} = Issho.join_as(MyApp.Issho, bot, "board:42")
{:ok, _snapshot} = Issho.Participant.open(agent, "board:42")
{:ok, _receipt} = Issho.Participant.transact(agent, "board:42", ops)
Issho.Participant.leave(agent)
```

or runs tools with `Issho.Tools.call/4`, as your model would.

## Writing a tool

```elixir
defmodule MyApp.Tools.Rename do
  use Issho.Tool,
    name: "rename_board",
    description: "Renames a board.",
    annotations: [idempotent: true]

  arg :board, :string, required: true
  arg :title, :string, required: true, max_length: 120

  alias Issho.Tool.Context

  @impl true
  def call(%{board: board, title: title}, ctx) do
    with {:ok, agent, _document, _snapshot} <- Context.open(ctx, board),
         {:ok, _receipt} <- Issho.Participant.transact(agent, board, [%{"op" => "set", "path" => ["title"], "value" => title}]) do
      {:ok, "Renamed."}
    else
      {:error, reason} -> Context.error(reason)
    end
  end
end
```

It serves your model and MCP clients alike.

## Trying it

Hakushi's and Kotoba's development apps serve their tools at `/mcp`,
with no authorization. With `mix dev` running and a canvas or a notebook
open in a browser:

```
claude mcp add --transport http hakushi-dev http://localhost:4099/mcp
```

then ask Claude Code to work on the canvas (`atelier:schema`), and watch
its pointer in the browser.
