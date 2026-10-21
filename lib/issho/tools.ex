defmodule Issho.Tools do
  @moduledoc ~S"""
  Tools for agents, for any way an agent reaches your app. Issho's room
  tools are `room/0`; the components bring theirs
  (`Kotoba.Issho.tools/0`, `Hakushi.Issho.tools/0`), and you can write
  your own (`Issho.Tool`).

  For your app's own model, through its API: give it the tools'
  definitions, and run the ones it calls as its agent.

      tools = Issho.Tools.room() ++ Kotoba.Issho.tools()
      ctx = Issho.Tool.Context.new(MyApp.Issho, assistant, on_behalf_of: current_user)

      # The `tools` of a request to the model:
      Issho.Tools.schemas(tools)

      # Each tool use in its answer:
      Issho.Tools.call(tools, name, input, ctx)

  For MCP clients, serve the same tools with `Issho.MCP`.
  """

  alias Issho.Tool

  @doc "Issho's tools for rooms: join, look around, read, point, say what you do, change, leave."
  @spec room() :: [module()]
  def room,
    do: [
      Issho.Tools.JoinRoom,
      Issho.Tools.LookAround,
      Issho.Tools.ReadDocument,
      Issho.Tools.Point,
      Issho.Tools.SetStatus,
      Issho.Tools.ChangeDocument,
      Issho.Tools.LeaveRoom
    ]

  @doc """
  The tools' definitions, as a model's API takes them: `name`,
  `description` and `input_schema` (a JSON Schema) for each.
  """
  @spec schemas([module()]) :: [map()]
  def schemas(tools) do
    for tool <- tools,
        do: %{
          "name" => tool.name(),
          "description" => tool.description(),
          "input_schema" => tool.input_schema()
        }
  end

  @doc """
  Runs the tool of that name with the input a model gave, as the agent of
  the context. Gives `{:ok, result}` or `{:error, text}`, for the model.
  """
  @spec call([module()], String.t(), map(), Tool.Context.t()) :: Tool.result()
  def call(tools, name, input, %Tool.Context{} = ctx) do
    case Enum.find(tools, &(&1.name() == name)) do
      nil -> {:error, "There is no tool #{inspect(name)}."}
      tool -> run(tool, input, ctx)
    end
  end

  @doc "Runs a tool with its input, as the agent of the context."
  @spec run(module(), map(), Tool.Context.t()) :: Tool.result()
  def run(tool, input, %Tool.Context{} = ctx) do
    with {:ok, args} <- Tool.cast(tool, input), do: tool.call(args, ctx)
  end

  @doc false
  # The room as a model reads it.
  def people(participant, self_key) do
    participant
    |> Issho.Participant.people()
    |> Enum.map(fn {key, %{"person" => person, "places" => places}} ->
      %{
        "key" => key,
        "name" => person["name"],
        "kind" => person["kind"],
        "you" => key == self_key,
        "can" => person["can"],
        "on_behalf_of" => get_in(person, ["on_behalf_of", "name"]),
        "places" => places
      }
    end)
    |> Enum.sort_by(&{not &1["you"], &1["name"] || &1["key"]})
  end
end

defmodule Issho.Tools.JoinRoom do
  @moduledoc false
  use Issho.Tool,
    name: "join_room",
    description: """
    Joins a room as yourself, an agent: the people in it see you, where
    you point and what you change. Gives who is here and where they are.
    You stay in the room between calls, and leave after a while with
    nothing to do, or with leave_room.
    """,
    annotations: [idempotent: true]

  arg :room, :string, required: true, description: "The room, as the app names it: board:42"

  alias Issho.Tool.Context

  @impl true
  def call(%{room: room}, ctx) do
    case Context.join(ctx, room) do
      {:ok, participant} ->
        key = Context.key(ctx)
        {:ok, %{"room" => room, "you" => key, "people" => Issho.Tools.people(participant, key)}}

      {:error, reason} ->
        Context.error(reason)
    end
  end
end

defmodule Issho.Tools.LookAround do
  @moduledoc false
  use Issho.Tool,
    name: "look_around",
    description: """
    Who is in the room now, and where each of them is: the place each
    person's cursor or selection is, in the terms of the document they
    are in.
    """,
    annotations: [read_only: true, idempotent: true]

  arg :room, :string, required: true

  alias Issho.Tool.Context

  @impl true
  def call(%{room: room}, ctx) do
    case Context.join(ctx, room) do
      {:ok, participant} ->
        {:ok, %{"people" => Issho.Tools.people(participant, Context.key(ctx))}}

      {:error, reason} ->
        Context.error(reason)
    end
  end
end

defmodule Issho.Tools.ReadDocument do
  @moduledoc false
  use Issho.Tool,
    name: "read_document",
    description: """
    Reads a document of the room as its engine holds it: its engine, its
    revision and its state. A component's own tools (Kotoba's text,
    Hakushi's canvas) read it in friendlier terms; prefer them.
    """,
    annotations: [read_only: true, idempotent: true]

  arg :room, :string, required: true
  arg :document, :string, description: "A document of the room; the room itself unless given"

  alias Issho.Tool.Context

  @impl true
  def call(args, ctx) do
    case Context.open(ctx, args.room, args[:document]) do
      {:ok, _participant, document, snapshot} ->
        state = snapshot["state"]

        {:ok,
         %{
           "document" => document,
           "engine" => snapshot["engine"],
           "revision" => snapshot["revision"],
           "state" =>
             if(json?(state), do: state, else: "(not JSON: use the component's own tools)")
         }}

      {:error, reason} ->
        Context.error(reason)
    end
  end

  defp json?(value) do
    _ = JSON.encode!(value)
    true
  rescue
    _ -> false
  end
end

defmodule Issho.Tools.Point do
  @moduledoc false
  use Issho.Tool,
    name: "point",
    description: """
    Shows the others where you are: a place in a document, in the
    document's own terms (a node of a canvas, a cell of a grid, a
    selection of a text). Without `at`, you point nowhere.
    """,
    annotations: [idempotent: true]

  arg :room, :string, required: true
  arg :document, :string, description: "A document of the room; the room itself unless given"
  arg :at, :any, description: "The place, as the document's component describes it"

  alias Issho.Tool.Context

  @impl true
  def call(args, ctx) do
    document = args[:document] || args.room
    place = if args[:at], do: %{"doc" => document, "at" => args.at}

    with {:ok, participant, _document, _snapshot} <- Context.open(ctx, args.room, document),
         :ok <- Issho.Participant.place(participant, place) do
      {:ok, if(place, do: "Pointing at it.", else: "Pointing nowhere.")}
    else
      {:error, reason} -> Context.error(reason)
    end
  end
end

defmodule Issho.Tools.SetStatus do
  @moduledoc false
  use Issho.Tool,
    name: "set_status",
    description: """
    A few words the others see beside your name while you work:
    "Reading the schema", "Drafting the summary". Empty clears it.
    """,
    annotations: [idempotent: true]

  arg :room, :string, required: true
  arg :status, :string, required: true, max_length: 120

  alias Issho.Tool.Context

  @impl true
  def call(%{room: room, status: status}, ctx) do
    status = if status == "", do: nil, else: status

    with {:ok, participant} <- Context.join(ctx, room),
         :ok <- Issho.Participant.aware(participant, %{"status" => status}) do
      {:ok, "Status set."}
    else
      {:error, reason} -> Context.error(reason)
    end
  end
end

defmodule Issho.Tools.ChangeDocument do
  @moduledoc false
  use Issho.Tool,
    name: "change_document",
    description: """
    Changes a document with its engine's own operations, as one
    transaction: all of them apply, or none. A component's own tools
    (Kotoba's, Hakushi's) make its changes in friendlier terms; prefer
    them.
    """,
    annotations: [destructive: true]

  arg :room, :string, required: true
  arg :document, :string, description: "A document of the room; the room itself unless given"
  arg :ops, {:array, :any}, required: true, description: "The engine's operations"

  alias Issho.Tool.Context

  @impl true
  def call(args, ctx) do
    with {:ok, participant, document, _snapshot} <- Context.open(ctx, args.room, args[:document]),
         {:ok, receipt} <- Issho.Participant.transact(participant, document, args.ops) do
      {:ok, %{"revision" => receipt["revision"]}}
    else
      {:error, reason} -> Context.error(reason)
    end
  end
end

defmodule Issho.Tools.LeaveRoom do
  @moduledoc false
  use Issho.Tool,
    name: "leave_room",
    description: "Leaves the room: the others no longer see you.",
    annotations: [idempotent: true]

  arg :room, :string, required: true

  alias Issho.Tool.Context

  @impl true
  def call(%{room: room}, ctx) do
    :ok = Context.leave(ctx, room)
    {:ok, "Left #{room}."}
  end
end
