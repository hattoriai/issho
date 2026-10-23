# The page layer in a browser: two pages of one room, with Issho's people
# list and pointers, a block of the page that says where its places are and
# which is under a pointer, and an agent that the tests drive over HTTP.
#
#   MIX_ENV=test mix run --no-halt e2e/server.exs
#
# PORT (4097 by default) is the port. The browser tests (e2e/specs) start it.

root = Path.expand("..", __DIR__)
static = Path.join(__DIR__, "static")
File.mkdir_p!(static)

# The page's script: Phoenix, LiveView and Issho, from their sources.
{_, 0} =
  System.cmd(
    Path.join(root, "assets/node_modules/.bin/esbuild"),
    ["e2e/app.js", "--bundle", "--format=esm", "--outfile=#{Path.join(static, "app.js")}"],
    cd: root,
    env: [{"NODE_PATH", Path.join(root, "assets/node_modules")}],
    into: IO.stream()
  )

File.cp!(Path.join(root, "assets/css/issho.css"), Path.join(static, "issho.css"))

defmodule IsshoE2E.Policy do
  @moduledoc false
  @behaviour Issho.Policy
  @impl true
  def authorize(_identity, _room, _action), do: :ok
  @impl true
  def document(_identity, id), do: {:ok, %{engine: IsshoTest.Binding, initial: %{"doc" => id}}}
end

defmodule IsshoE2E.Channel do
  @moduledoc false
  use Issho.Channel, instance: IsshoE2E.Issho
end

defmodule IsshoE2E.Socket do
  @moduledoc false
  use Phoenix.Socket
  channel "issho:*", IsshoE2E.Channel
  @impl true
  def connect(_params, socket, _info), do: {:ok, socket}
  @impl true
  def id(_socket), do: nil
end

defmodule IsshoE2E.Agent do
  @moduledoc false
  # One agent, whose participants live as long as the server: each tool
  # runs in this process, as an MCP session's would. A test names a session
  # of its own for a context of its own (the agent at work for someone).
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def call(tool, arguments, session \\ "a", on_behalf_of \\ nil),
    do: GenServer.call(__MODULE__, {tool, arguments, session, on_behalf_of}, 30_000)

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_call({tool, arguments, session, on_behalf_of}, _from, contexts) do
    opts = if on_behalf_of, do: [on_behalf_of: %{id: on_behalf_of, name: on_behalf_of}], else: []

    context =
      Map.get_lazy(contexts, session, fn ->
        Issho.Tool.Context.new(
          IsshoE2E.Issho,
          %{id: "agent:e2e", name: "Agent", kind: :agent},
          opts
        )
      end)

    {:reply, Issho.Tools.call(Issho.Tools.room(), tool, arguments, context),
     Map.put(contexts, session, context)}
  end
end

defmodule IsshoE2E.AgentPlug do
  @moduledoc false
  # POST /agent {"tool": ..., "arguments": {...}, "session": "a", "on_behalf_of": "Ada"}
  @behaviour Plug
  def init(opts), do: opts

  def call(conn, _opts) do
    %{"tool" => tool, "arguments" => arguments} = conn.body_params

    reply =
      case IsshoE2E.Agent.call(
             tool,
             arguments,
             conn.body_params["session"] || "a",
             conn.body_params["on_behalf_of"]
           ) do
        {:ok, result} -> %{"result" => result}
        {:error, reason} -> %{"error" => inspect(reason)}
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, JSON.encode!(reply))
  end
end

defmodule IsshoE2E.Layouts do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Issho e2e</title>
        <link rel="stylesheet" href="/issho.css" />
        <style>
          body { font: 16px/1.5 system-ui, sans-serif; margin: 0; padding: 24px; }
          header { display: flex; gap: 1rem; align-items: center; min-height: 40px; }
          #list { list-style: none; margin: 24px 0; padding: 0; display: flex; flex-direction: column; width: 320px; }
          #list[data-order="desc"] { flex-direction: column-reverse; }
          #list li { height: 40px; border: 1px solid #ddd; padding: 0 12px; display: flex; align-items: center; }
          .spacer { height: 1600px; }
          #elsewhere { width: 320px; height: 120px; border: 1px dashed #999; margin: 24px 0; }
        </style>
        <script type="module" src="/app.js"></script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end

defmodule IsshoE2E.PageLive do
  @moduledoc false
  # /one and /two: two pages of a room. ?as= the person, ?agents=on_behalf
  # follows the agents at work for them, ?order=desc draws
  # the block's items the other way round, ?long=1 puts it below the fold,
  # ?far=1 puts the block of another room (#elsewhere) below the fold.
  use Phoenix.LiveView
  on_mount Issho.Live

  @impl true
  def mount(params, _session, socket) do
    room = "page:" <> Map.get(params, "room", "main")
    name = Map.get(params, "as", "Ada")
    actor = %{id: name, name: name}

    {:ok,
     assign(socket,
       room: room,
       name: name,
       query: Map.take(params, ["room", "as", "order", "far", "agents", "comments"]),
       comments: comments(socket, params["comments"] == "1", actor, room),
       follow_agents: if(params["agents"] == "on_behalf", do: "on_behalf"),
       order: if(params["order"] == "desc", do: "desc", else: "asc"),
       long: params["long"] == "1",
       far: params["far"] == "1",
       grant: Issho.Live.grant(IsshoE2E.Issho, actor, room)
     )}
  end

  # ?comments=1: the room's comments beside the page, for which the
  # LiveView is in the room itself.
  defp comments(socket, wanted, actor, room) do
    if wanted and connected?(socket), do: {:ok, _} = Issho.Live.join(IsshoE2E.Issho, actor, room)
    wanted
  end

  @impl true
  def handle_params(_params, uri, socket),
    do: {:noreply, assign(socket, :page, URI.parse(uri).path)}

  @impl true
  def render(assigns) do
    ~H"""
    <header>
      <h1 id="title">{if @page == "/two", do: "Page two", else: "Page one"}</h1>
      <Issho.Components.people id="people" grant={@grant} />
    </header>
    <div :if={@long} class="spacer"></div>
    <ul id="list" data-issho-doc={@room <> "/list"} data-order={@order} phx-hook="E2EList">
      <li :for={n <- 1..8} data-item={n}>Item {n}</li>
    </ul>
    <div :if={@far} class="spacer"></div>
    <%!-- A block of another room (a canvas shared in its own room): that room draws its people there. --%>
    <div id="elsewhere" data-issho-doc={"other:" <> @room}>A block of another room</div>
    <.link id="next" navigate={"/two?" <> URI.encode_query(@query)} data-issho-anchor="next" data-issho-follow>
      Next page
    </.link>
    <Issho.Components.agents id="agents" grant={@grant} />
    <Issho.Components.comments :if={@comments} id="comments" room={@room} />
    <Issho.Components.pointers id="pointers" grant={@grant} follow_agents={@follow_agents} />
    """
  end
end

defmodule IsshoE2E.FormLive do
  @moduledoc false
  # /form: a form with a shared component in it (E2EForm, a member of
  # Issho's holdForm with nothing to send), and how many times it went.
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, saved: 0)}

  @impl true
  def handle_event("save", _params, socket), do: {:noreply, update(socket, :saved, &(&1 + 1))}

  @impl true
  def render(assigns) do
    ~H"""
    <form id="form" phx-submit="save">
      <div id="member" phx-hook="E2EForm"></div>
      <button id="publish" type="submit">Publish</button>
    </form>
    <p id="saved">Saved {@saved}</p>
    """
  end
end

defmodule IsshoE2E.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {IsshoE2E.Layouts, :root}
  end

  scope "/" do
    post "/agent", IsshoE2E.AgentPlug, []
  end

  scope "/" do
    pipe_through :browser

    live_session :pages do
      live "/one", IsshoE2E.PageLive
      live "/two", IsshoE2E.PageLive
      live "/form", IsshoE2E.FormLive
    end
  end
end

defmodule IsshoE2E.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :issho

  @session [store: :cookie, key: "_issho_e2e", signing_salt: "issho-e2e"]

  socket "/issho/socket", IsshoE2E.Socket, websocket: true, longpoll: false
  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]

  plug Plug.Static, at: "/", from: Path.expand("static", __DIR__), only: ~w(app.js issho.css)
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: JSON
  plug Plug.Session, @session
  plug IsshoE2E.Router
end

Logger.configure(level: :info)
port = String.to_integer(System.get_env("PORT", "4097"))

Application.put_env(:issho, IsshoE2E.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: port],
  server: true,
  secret_key_base: String.duplicate("issho-e2e-secret-", 4),
  live_view: [signing_salt: "issho-e2e-live"],
  # A local test server: pages on 127.0.0.1, whatever its url says.
  check_origin: false,
  pubsub_server: IsshoE2E.PubSub
)

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: IsshoE2E.PubSub},
      {Issho.Store.Memory, name: IsshoE2E.Store},
      {Issho,
       name: IsshoE2E.Issho,
       pubsub: IsshoE2E.PubSub,
       endpoint: IsshoE2E.Endpoint,
       policy: IsshoE2E.Policy,
       store: {Issho.Store.Memory, IsshoE2E.Store}},
      IsshoE2E.Endpoint,
      IsshoE2E.Agent
    ],
    strategy: :one_for_one
  )

IO.puts("Issho e2e: http://127.0.0.1:#{port}/one")

# The supervisor is linked to this script: it lives as long as the script.
Process.sleep(:infinity)
