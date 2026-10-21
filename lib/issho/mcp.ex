defmodule Issho.MCP.Setup do
  @moduledoc ~S"""
  Issho's MCP settings for one endpoint, as a plug before it: which
  instance, and who its callers are in the rooms. An app can serve
  `Issho.MCP` on several endpoints, each with its own:

      pipeline :people_mcp do
        # Each person's own agent, acting on their behalf.
        plug Issho.MCP.Setup, agent: {MyApp.Collaboration, :assistant}
      end

      pipeline :bot_mcp do
        # The app's own bot, acting as itself.
        plug Issho.MCP.Setup, agent: {MyApp.Collaboration, :bot}
      end

  Options: `:instance` and `:agent`, as in `Issho.MCP.Session`. What a
  plug sets wins over the `config :issho, Issho.MCP` of the app.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: Keyword.take(opts, [:instance, :agent])

  @impl true
  def call(conn, opts), do: Plug.Conn.assign(conn, :issho, opts)
end

defmodule Issho.MCP.Session do
  @moduledoc ~S"""
  Who an MCP caller is in Issho's rooms, for the tools of `Issho.MCP`
  and of the bindings' servers (Kotoba's, Hakushi's).

  A caller is an actor of the app's choosing, as anyone in a room is:

    * a person's own agent, acting on their behalf (`on_behalf_of`), so
      that the policy can let it do what the person may;
    * the app's bot, or the system, acting as itself, for no one
      (`kind: :agent` or `:service`, no `on_behalf_of`);
    * an agent for a team, a customer, a workspace, with `claims` the
      policy reads.

  An app can have all of them at once: on one endpoint, deciding from the
  call (a person's token, a service's client credentials), or on several
  endpoints, each with its own settings (`Issho.MCP.Setup`).

  The settings, in the app's config or from `Issho.MCP.Setup`:

      config :issho, Issho.MCP,
        instance: MyApp.Issho,
        agent: {MyApp.Collaboration, :agent},
        idle: 600_000

  `agent` is `{module, function}` or a function of one argument, called
  with the call's `Sake.Context` (its `scope` is the principal the
  endpoint's authorization, any of Sake's or your own, put there; nil
  without one). It gives `{actor, opts}`: the actor, and the options of
  its join (`:on_behalf_of`, `:claims`, `:can`):

      def agent(%Sake.Context{scope: %MyApp.User{} = user}),
        do: {%{id: "assistant:#{user.id}", name: "Assistant", kind: :agent}, on_behalf_of: user}

      def agent(%Sake.Context{scope: %MyApp.Service{} = service}),
        do: {%{id: "service:#{service.id}", name: service.name, kind: :service}, []}

  Without `agent`, the caller is an agent named for its MCP client
  ("Claude Code"): on behalf of the principal when the principal is an
  `Issho.Actor`, or acting as itself when there is none.
  """

  alias Issho.{Agents, Identity}

  @doc "The caller's participant in the room, joining it if it is not there."
  @spec join(Sake.Context.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def join(ctx, room) when is_binary(room) do
    {actor, opts} = agent(ctx)
    idle = setting(ctx, :idle) || 600_000
    Agents.join(instance(ctx), actor, room, Keyword.put_new(opts, :idle, idle))
  end

  @doc "The caller's participant in the room, with the document open."
  @spec open(Sake.Context.t(), String.t(), String.t() | nil) ::
          {:ok, pid(), String.t(), map()} | {:error, term()}
  def open(ctx, room, document \\ nil) do
    document = document || room

    with {:ok, participant} <- join(ctx, room),
         {:ok, snapshot} <- Issho.Participant.open(participant, document),
         do: {:ok, participant, document, snapshot}
  end

  @doc "The caller's key in the rooms."
  @spec key(Sake.Context.t()) :: String.t()
  def key(ctx) do
    {actor, _opts} = agent(ctx)
    Identity.new(actor).key
  end

  @doc "Takes the caller out of the room."
  @spec leave(Sake.Context.t(), String.t()) :: :ok
  def leave(ctx, room), do: Agents.leave(instance(ctx), key(ctx), room)

  @doc "The Issho instance of the call."
  @spec instance(Sake.Context.t()) :: atom()
  def instance(ctx) do
    setting(ctx, :instance) ||
      raise ArgumentError,
            "Issho.MCP needs an instance: `config :issho, Issho.MCP, instance: MyApp.Issho`, or Issho.MCP.Setup"
  end

  @doc "A tool's error, as text the model reads."
  @spec error(term()) :: {:error, String.t()}
  def error(:forbidden), do: {:error, "The room's policy does not allow this."}
  def error(:read_only), do: {:error, "You may only read in this room."}
  def error(:not_open), do: {:error, "Open the document first."}
  def error(:other_room), do: {:error, "That document is not in this room."}
  def error(reason) when is_binary(reason), do: {:error, reason}
  def error(reason), do: {:error, "Refused: #{inspect(reason)}"}

  defp agent(ctx) do
    case setting(ctx, :agent) do
      {module, function} -> apply(module, function, [ctx])
      function when is_function(function, 1) -> function.(ctx)
      nil -> default_agent(ctx)
    end
  end

  defp default_agent(ctx) do
    client = ctx.client_info || %{}
    name = client["title"] || client["name"] || "Agent"
    person = person(ctx.scope)
    who = if person, do: ":" <> person.key, else: ""

    actor = %{id: "agent:" <> slug(client["name"] || name) <> who, name: name, kind: :agent}
    {actor, if(person, do: [on_behalf_of: person], else: [])}
  end

  defp person(nil), do: nil

  defp person(scope) do
    Identity.new(scope)
  rescue
    _not_an_actor -> nil
  end

  defp slug(name),
    do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  # An endpoint's own settings (Issho.MCP.Setup), else the app's.
  defp setting(ctx, key) do
    endpoint = (ctx.conn_assigns || %{})[:issho] || []
    Keyword.get(endpoint, key) || Keyword.get(Application.get_env(:issho, Issho.MCP, []), key)
  end
end

defmodule Issho.MCP.Format do
  @moduledoc false
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

  def json?(value) do
    _ = JSON.encode!(value)
    true
  rescue
    _ -> false
  end
end

defmodule Issho.MCP.JoinRoom do
  @moduledoc false
  use Sake.Tool,
    name: "join_room",
    description: """
    Joins a room as yourself, an agent: the people in it see you, where
    you point and what you change. Gives who is here and where they are.
    You stay in the room between calls, and leave after a while with
    nothing to do, or with leave_room.
    """,
    annotations: [idempotent: true, open_world: false]

  arg :room, :string, required: true, description: "The room, as the app names it: board:42"

  alias Issho.MCP.{Format, Session}

  @impl true
  def execute(%{room: room}, ctx) do
    case Session.join(ctx, room) do
      {:ok, participant} ->
        key = Session.key(ctx)
        {:ok, %{"room" => room, "you" => key, "people" => Format.people(participant, key)}}

      {:error, reason} ->
        Session.error(reason)
    end
  end
end

defmodule Issho.MCP.LookAround do
  @moduledoc false
  use Sake.Tool,
    name: "look_around",
    description: """
    Who is in the room now, and where each of them is: the place each
    person's cursor or selection is, in the terms of the document they
    are in.
    """,
    annotations: [read_only: true, idempotent: true, open_world: false]

  arg :room, :string, required: true

  alias Issho.MCP.{Format, Session}

  @impl true
  def execute(%{room: room}, ctx) do
    case Session.join(ctx, room) do
      {:ok, participant} -> {:ok, %{"people" => Format.people(participant, Session.key(ctx))}}
      {:error, reason} -> Session.error(reason)
    end
  end
end

defmodule Issho.MCP.ReadDocument do
  @moduledoc false
  use Sake.Tool,
    name: "read_document",
    description: """
    Reads a document of the room as its engine holds it: its engine, its
    revision and its state. A component's own tools (Kotoba's text,
    Hakushi's canvas) read it in friendlier terms; prefer them.
    """,
    annotations: [read_only: true, idempotent: true, open_world: false]

  arg :room, :string, required: true
  arg :document, :string, description: "A document of the room; the room itself unless given"

  alias Issho.MCP.{Format, Session}

  @impl true
  def execute(args, ctx) do
    case Session.open(ctx, args.room, args[:document]) do
      {:ok, _participant, document, snapshot} ->
        state = snapshot["state"]

        {:ok,
         %{
           "document" => document,
           "engine" => snapshot["engine"],
           "revision" => snapshot["revision"],
           "state" =>
             if(Format.json?(state),
               do: state,
               else: "(not JSON: use the component's own tools)"
             )
         }}

      {:error, reason} ->
        Session.error(reason)
    end
  end
end

defmodule Issho.MCP.Point do
  @moduledoc false
  use Sake.Tool,
    name: "point",
    description: """
    Shows the others where you are: a place in a document, in the
    document's own terms (a node of a canvas, a cell of a grid, a
    selection of a text). Without `at`, you point nowhere.
    """,
    annotations: [idempotent: true, open_world: false]

  arg :room, :string, required: true
  arg :document, :string, description: "A document of the room; the room itself unless given"
  arg :at, :any, description: "The place, as the document's component describes it"

  alias Issho.MCP.Session

  @impl true
  def execute(args, ctx) do
    document = args[:document] || args.room
    place = if args[:at], do: %{"doc" => document, "at" => args.at}

    with {:ok, participant, _document, _snapshot} <- Session.open(ctx, args.room, document),
         :ok <- Issho.Participant.place(participant, place) do
      {:ok, if(place, do: "Pointing at it.", else: "Pointing nowhere.")}
    else
      {:error, reason} -> Session.error(reason)
    end
  end
end

defmodule Issho.MCP.SetStatus do
  @moduledoc false
  use Sake.Tool,
    name: "set_status",
    description: """
    A few words the others see beside your name while you work:
    "Reading the schema", "Drafting the summary". Empty clears it.
    """,
    annotations: [idempotent: true, open_world: false]

  arg :room, :string, required: true
  arg :status, :string, required: true, max_length: 120

  alias Issho.MCP.Session

  @impl true
  def execute(%{room: room, status: status}, ctx) do
    status = if status == "", do: nil, else: status

    with {:ok, participant} <- Session.join(ctx, room),
         :ok <- Issho.Participant.aware(participant, %{"status" => status}) do
      {:ok, "Status set."}
    else
      {:error, reason} -> Session.error(reason)
    end
  end
end

defmodule Issho.MCP.ChangeDocument do
  @moduledoc false
  use Sake.Tool,
    name: "change_document",
    description: """
    Changes a document with its engine's own operations, as one
    transaction: all of them apply, or none. A component's own tools
    (Kotoba's, Hakushi's) make its changes in friendlier terms; prefer
    them.
    """,
    annotations: [destructive: true, open_world: false]

  arg :room, :string, required: true
  arg :document, :string, description: "A document of the room; the room itself unless given"
  arg :ops, {:array, :any}, required: true, description: "The engine's operations"

  alias Issho.MCP.Session

  @impl true
  def execute(args, ctx) do
    with {:ok, participant, document, _snapshot} <-
           Session.open(ctx, args.room, args[:document]),
         {:ok, receipt} <- Issho.Participant.transact(participant, document, args.ops) do
      {:ok, %{"revision" => receipt["revision"]}}
    else
      {:error, reason} -> Session.error(reason)
    end
  end
end

defmodule Issho.MCP.LeaveRoom do
  @moduledoc false
  use Sake.Tool,
    name: "leave_room",
    description: "Leaves the room: the others no longer see you.",
    annotations: [idempotent: true, open_world: false]

  arg :room, :string, required: true

  alias Issho.MCP.Session

  @impl true
  def execute(%{room: room}, ctx) do
    :ok = Session.leave(ctx, room)
    {:ok, "Left #{room}."}
  end
end

defmodule Issho.MCP do
  @moduledoc ~S"""
  Agents in Issho's rooms over MCP, with [Sake](https://hex.pm/packages/sake):
  an agent joins a room, sees who is there and where, points, says what
  it is doing, reads and changes documents, as a person does, and the
  people see it there.

  It is a `Sake.Server` like any other: serve it how your app serves
  MCP, over HTTP or stdio, with Sake's authorization, your own, or none,
  on its own endpoint or mounted in your server, next to the servers of
  the components you use (`Kotoba.Issho.MCP`, `Hakushi.Issho.MCP`):

      defmodule MyApp.MCP do
        use Sake.Server, name: "my-app", version: "1.0.0"
        mount Issho.MCP
        mount Kotoba.Issho.MCP
      end

      # config/config.exs
      config :issho, Issho.MCP, instance: MyApp.Issho

  The agent acts under your policy, as anyone in a room does, and on
  behalf of the person your endpoint signed in (see
  `Issho.MCP.Session`): `authorize/3` sees an identity of `kind:
  :agent` with `on_behalf_of` that person.
  """

  @version Mix.Project.config()[:version]

  use Sake.Server,
    name: "issho",
    version: @version,
    instructions: """
    Rooms where people and agents work together live. join_room first:
    the people there see you. look_around says who is here and where.
    Point at what you work on, set_status to say what you are doing,
    then read and change documents, preferably with the tools of the
    document's component. leave_room when you are done.
    """

  tools([
    Issho.MCP.JoinRoom,
    Issho.MCP.LookAround,
    Issho.MCP.ReadDocument,
    Issho.MCP.Point,
    Issho.MCP.SetStatus,
    Issho.MCP.ChangeDocument,
    Issho.MCP.LeaveRoom
  ])
end
