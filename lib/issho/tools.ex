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

  @doc "Issho's tools for rooms: join, look around, read, point, click, say what you do, change, leave."
  @spec room() :: [module()]
  def room,
    do: [
      Issho.Tools.JoinRoom,
      Issho.Tools.LookAround,
      Issho.Tools.ReadDocument,
      Issho.Tools.Point,
      Issho.Tools.Click,
      Issho.Tools.Navigate,
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

  @doc """
  Runs a tool with its input, as the agent of the context, within the
  time budget of a tool call: the gestures it makes together take no
  longer (`Issho.Motion`).
  """
  @spec run(module(), map(), Tool.Context.t()) :: Tool.result()
  def run(tool, input, %Tool.Context{} = ctx) do
    with {:ok, args} <- Tool.cast(tool, input),
         do: Issho.Motion.within(fn -> tool.call(args, ctx) end)
  end

  @doc """
  A person of the room, by their name (any case) or their key: their
  name, and each of their sessions' awareness states, for a component's
  tool that acts on what someone selected ("connect what Ada selected").
  Gives `{:ok, %{name: name, key: key, states: [state]}}`, or an error in
  words.
  """
  @spec person_of(GenServer.server(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def person_of(participant, who) when is_binary(who) do
    wanted = who |> String.trim() |> String.downcase()

    participant
    |> Issho.Participant.people()
    |> Enum.find(fn {key, %{"person" => person}} ->
      String.downcase(key) == wanted or String.downcase(person["name"] || "") == wanted
    end)
    |> case do
      nil ->
        {:error, "No one called #{inspect(who)} is in the room."}

      {key, %{"person" => person, "states" => states}} ->
        {:ok, %{name: person["name"] || key, key: key, states: states}}
    end
  end

  @doc """
  Where a person of the room is in a document: their place's `"at"`, in
  the document's own terms ("rewrite what Ada selected"). Gives
  `{:ok, at, name}`, or an error in words.
  """
  @spec place_of(GenServer.server(), String.t(), String.t()) ::
          {:ok, term(), String.t()} | {:error, String.t()}
  def place_of(participant, document, who) when is_binary(who) do
    with {:ok, %{name: name, states: states}} <- person_of(participant, who) do
      case Enum.find(states, &match?(%{"place" => %{"doc" => ^document}}, &1)) do
        %{"place" => %{"at" => at}} -> {:ok, at, name}
        nil -> {:error, "#{name} is not in #{document}."}
      end
    end
  end

  @doc false
  # The elements the people's pages name (data-issho-anchor), as their
  # browsers say them: once each, with its label, and whether a click on it
  # takes the people who follow the agent along (a link, a button).
  def anchors(participant) do
    participant
    |> Issho.Participant.people()
    |> Enum.flat_map(fn {_key, %{"states" => states}} -> states end)
    |> Enum.flat_map(&List.wrap(view(&1)["anchors"]))
    |> Enum.filter(&(is_map(&1) and is_binary(&1["name"])))
    |> Enum.uniq_by(& &1["name"])
    |> Enum.map(&Map.take(&1, ["name", "label", "follow", "href"]))
    |> Enum.take(100)
  end

  @doc false
  # The room as a model reads it.
  def people(participant, self_key) do
    participant
    |> Issho.Participant.people()
    |> Enum.map(fn {key, %{"person" => person, "places" => places} = entry} ->
      %{
        "key" => key,
        "name" => person["name"],
        "kind" => person["kind"],
        "you" => key == self_key,
        "can" => person["can"],
        "on_behalf_of" => get_in(person, ["on_behalf_of", "name"]),
        "places" => places,
        "pages" => pages(Map.get(entry, "states", []))
      }
    end)
    |> Enum.sort_by(&{not &1["you"], &1["name"] || &1["key"]})
  end

  # The pages of the app a person has open (each browser's path), or the
  # page an agent went to.
  defp pages(states) do
    states
    |> Enum.map(&(view(&1)["path"] || &1["path"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  # What a browser says its page shows. Only a map: a state is shared by
  # the page's components, and another's key of that name is not it.
  defp view(%{"view" => %{} = view}), do: view
  defp view(_state), do: %{}
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
    Who is in the room now, and where each of them is: the pages of the
    app they have open (`pages`), and the place each person's cursor or
    selection is, in the terms of the document they are in. To act on
    what someone selected, give their name as `of` to a component's tool
    ("the text Ada selected"). And the elements of the people's pages
    that you can point at and click (`anchors`), by their name and their
    label, and for a link where it goes (`href`).
    """,
    annotations: [read_only: true, idempotent: true]

  arg :room, :string, required: true

  alias Issho.Tool.Context

  @impl true
  def call(%{room: room}, ctx) do
    case Context.join(ctx, room) do
      {:ok, participant} ->
        {:ok,
         %{
           "people" => Issho.Tools.people(participant, Context.key(ctx)),
           "anchors" => Issho.Tools.anchors(participant)
         }}

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
    Shows the others where you are, your pointer going there: a place in
    a document, in the document's own terms (a node of a canvas, a cell of
    a grid, a selection of a text), or an element of the page by its
    anchor (see look_around). Without `at` or `anchor`, you point nowhere.
    """,
    annotations: [idempotent: true]

  arg :room, :string, required: true
  arg :document, :string, description: "A document of the room; the room itself unless given"
  arg :at, :any, description: "The place, as the document's component describes it"
  arg :anchor, :string, description: "An element of the page, by its anchor"

  alias Issho.Tool.Context

  @impl true
  def call(%{anchor: anchor} = args, ctx) when is_binary(anchor) do
    with {:ok, participant} <- Context.join(ctx, args.room),
         :ok <- Issho.Motion.go(participant, %{"anchor" => anchor}) do
      {:ok, "Pointing at it."}
    else
      {:error, reason} -> Context.error(reason)
    end
  end

  def call(args, ctx) do
    document = args[:document] || args.room

    with {:ok, participant, _document, _snapshot} <- Context.open(ctx, args.room, document),
         :ok <- point(participant, document, args[:at]) do
      {:ok, if(args[:at], do: "Pointing at it.", else: "Pointing nowhere.")}
    else
      {:error, reason} -> Context.error(reason)
    end
  end

  defp point(participant, _document, nil), do: Issho.Participant.place(participant, nil)

  defp point(participant, document, at),
    do: Issho.Motion.go(participant, %{"doc" => document, "at" => at})
end

defmodule Issho.Tools.Click do
  @moduledoc false
  use Issho.Tool,
    name: "click",
    description: """
    Clicks an element of the page, by its anchor (see look_around): your
    pointer goes there and the people see the click. A link or a button
    that takes people along (`follow` in look_around) takes those who
    follow you there too, as if they had clicked it.
    """,
    annotations: []

  arg :room, :string, required: true
  arg :anchor, :string, required: true, description: "The element, by its anchor"

  alias Issho.Tool.Context

  @impl true
  def call(%{room: room, anchor: anchor}, ctx) do
    with {:ok, participant} <- Context.join(ctx, room),
         :ok <- Issho.Motion.click(participant, %{"anchor" => anchor}) do
      {:ok, "Clicked."}
    else
      {:error, reason} -> Context.error(reason)
    end
  end
end

defmodule Issho.Tools.Navigate do
  @moduledoc false
  use Issho.Tool,
    name: "navigate",
    description: """
    Goes to another page of the app, by its path ("/pages/2", as a link's
    `href` in look_around says it): the people who follow you go there
    with you. You are in the rooms you joined, not in a page: to work in
    the documents of the page you went to, join its room.
    """,
    annotations: []

  arg :room, :string, required: true, description: "The room you are going from"
  arg :path, :string, required: true, description: "A path of the app, starting with /"

  alias Issho.Tool.Context

  @impl true
  def call(%{room: room, path: path}, ctx) do
    with {:ok, participant} <- Context.join(ctx, room),
         :ok <- Issho.Motion.navigate(participant, path) do
      {:ok, "Gone to #{path}."}
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
