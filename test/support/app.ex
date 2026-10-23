defmodule IsshoTest.Policy do
  @moduledoc false
  # The test app's policy: rooms "board:*" are maps, "canvas:*" its
  # components' (no document of the policy's); an actor whose key is
  # in the denied set may do nothing, and "readonly:*" rooms refuse :write.
  @behaviour Issho.Policy

  def deny(key), do: :persistent_term.put({__MODULE__, key}, true)
  def allow(key), do: :persistent_term.erase({__MODULE__, key})
  defp denied?(key), do: :persistent_term.get({__MODULE__, key}, false)

  # An action no one may do, until allowed again.
  def deny_action(action), do: :persistent_term.put({__MODULE__, :action, action}, true)
  def allow_action(action), do: :persistent_term.erase({__MODULE__, :action, action})
  defp denied_action?(action), do: :persistent_term.get({__MODULE__, :action, action}, false)

  @impl true
  def authorize(identity, room, action) do
    cond do
      denied?(identity.key) -> {:error, :forbidden}
      denied_action?(action) -> {:error, :forbidden}
      String.starts_with?(room, "readonly:") and action in [:write, :lock] -> {:error, :forbidden}
      true -> :ok
    end
  end

  @impl true
  def document(_identity, "missing:" <> _), do: {:error, :not_found}
  # A canvas's document is its component's (a spec it gives as it opens).
  def document(_identity, "canvas:" <> _), do: {:error, :not_found}

  def document(_identity, id) do
    {:ok, %{engine: IsshoTest.Binding, initial: %{"title" => "Untitled", "doc" => id}}}
  end
end

defmodule IsshoTest.Place do
  @moduledoc false
  # A place in a map: a key path.
  @behaviour Issho.Place

  @impl true
  def validate(%{"path" => path}) when is_list(path), do: :ok
  def validate(_place), do: {:error, :invalid_place}
end

defmodule IsshoTest.Binding do
  @moduledoc false
  use Issho.Binding, engine: Issho.Engine.Map, place: IsshoTest.Place
end

defmodule IsshoTest.Channel do
  @moduledoc false
  use Issho.Channel, instance: IsshoTest.Issho
end

defmodule IsshoTest.Socket do
  @moduledoc false
  use Phoenix.Socket
  channel "issho:*", IsshoTest.Channel
  @impl true
  def connect(_params, socket, _info), do: {:ok, socket}
  @impl true
  def id(_socket), do: nil
end

defmodule IsshoTest.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :issho
  socket "/issho/socket", IsshoTest.Socket
  socket "/live", Phoenix.LiveView.Socket
end

defmodule IsshoTest.LiveEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :issho
  socket "/issho/socket", IsshoTest.Socket, websocket: true, longpoll: false
end

defmodule IsshoTest.TitleComponent do
  @moduledoc false
  # A component that renders a shared document's title, and the number of
  # people, from the events Issho.Live sends it.
  use Phoenix.LiveComponent

  @impl true
  def mount(socket), do: {:ok, assign(socket, state: %{}, people: 0, bye: nil, seen: [])}

  @impl true
  def update(%{issho: {"tx", _doc, event}}, socket) do
    {:ok, state} = Issho.Engine.Map.apply(socket.assigns.state, event["ops"], [])
    {:ok, assign(socket, state: state, seen: [event["author"] | socket.assigns.seen])}
  end

  def update(%{issho: {"presence_diff", room, _diff}}, socket),
    do: {:ok, assign(socket, :people, map_size(Issho.Live.people(room)))}

  def update(%{issho: {"bye", _room, reason}}, socket), do: {:ok, assign(socket, :bye, reason)}
  def update(%{issho: {_event, _key, _payload}}, socket), do: {:ok, socket}

  def update(assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:snapshot]))

    if snapshot = assigns[:snapshot],
      do: {:ok, assign(socket, :state, snapshot["state"])},
      else: {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <h1>{@state["title"]}</h1>
      <p id="people">people: {@people}</p>
      <p :if={@bye} id="bye">bye: {@bye}</p>
    </div>
    """
  end
end

defmodule IsshoTest.GrantLive do
  @moduledoc false
  # A page whose browser half joins the room itself: a grant.
  use Phoenix.LiveView

  on_mount Issho.Live

  @impl true
  def mount(_params, %{"user" => user, "room" => room}, socket) do
    grant = Issho.Live.grant(IsshoTest.Issho, %{id: user, name: user}, room, can: :read)
    {:ok, assign(socket, grant: grant)}
  end

  @impl true
  def render(assigns), do: ~H"<div id='grant' data-room={Map.get(@grant, ~s(room))}></div>"
end

defmodule IsshoTest.BoardLive do
  @moduledoc false
  use Phoenix.LiveView

  on_mount Issho.Live

  @impl true
  def mount(_params, %{"user" => user, "room" => room}, socket) do
    socket = assign(socket, user: user, room: room, snapshot: nil, messages: [])

    if connected?(socket) do
      {:ok, _session} = Issho.Live.join(IsshoTest.Issho, %{id: user, name: user}, room)
      {:ok, snapshot} = Issho.Live.open(room, room, notify: {IsshoTest.TitleComponent, "title"})
      Issho.Live.subscribe(room, :self)
      {:ok, assign(socket, :snapshot, snapshot)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("rename", %{"title" => title}, socket) do
    {:ok, _} =
      Issho.Live.transact(socket.assigns.room, socket.assigns.room, [
        %{"op" => "set", "path" => ["title"], "value" => title}
      ])

    {:noreply, socket}
  end

  # The title says when it is released (its awareness of its own, say).
  def handle_event("watch", _params, socket) do
    parent = self()

    Issho.Live.subscribe(socket.assigns.room, {IsshoTest.TitleComponent, "title"},
      on_release: fn -> send(parent, {:released, "title"}) end
    )

    {:noreply, socket}
  end

  # The LiveView hears the room's events of a kind.
  def handle_event("listen", %{"names" => names}, socket) do
    Issho.Live.subscribe(socket.assigns.room, :self, events: names)
    {:noreply, socket}
  end

  # The title goes from the page, and with it, the LiveView's last
  # reason to be in the room unless it listens itself.
  def handle_event("release", params, socket) do
    room = socket.assigns.room
    Issho.Live.release(room, {IsshoTest.TitleComponent, "title"})
    if params["self"], do: Issho.Live.release(room, :self)
    {:noreply, assign(socket, :snapshot, nil)}
  end

  @impl true
  def handle_info({:released, what}, socket),
    do: {:noreply, update(socket, :messages, &["released: " <> what | &1])}

  def handle_info({Issho.Live, "event", _room, %Issho.Event{name: name}}, socket),
    do: {:noreply, update(socket, :messages, &["event:" <> name | &1])}

  def handle_info({Issho.Live, event, _key, _payload}, socket),
    do: {:noreply, update(socket, :messages, &[event | &1])}

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component :if={@snapshot} module={IsshoTest.TitleComponent} id="title" snapshot={@snapshot} />
    <p id="messages">{Enum.join(Enum.uniq(@messages), ",")}</p>
    """
  end
end

defmodule IsshoTest.UnhookedLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Issho.Live.join(IsshoTest.Issho, %{id: "x"}, "board:x")
    {:ok, socket}
  end

  @impl true
  def render(assigns), do: ~H"<p>unhooked</p>"
end

defmodule IsshoTest.Sync do
  @moduledoc false
  # Waits until a process has handled every message already in its
  # mailbox, and the messages it sent itself while doing so (a LiveView's
  # send_update): each :sys.get_state/1 is answered in mailbox order. For
  # waiting on another process without a sleep.
  def settle(pid) do
    :sys.get_state(pid)
    :sys.get_state(pid)
    :ok
  end
end

defmodule IsshoTest.MCP do
  @moduledoc false
  # Issho's room tools over MCP, as an app serves them.
  use Issho.MCP, name: "issho-test", version: "0.0.0", tools: Issho.Tools.room()
end

defmodule IsshoTest.RetroLive do
  @moduledoc false
  # A retro board: cards in columns, as shared state.
  use Phoenix.LiveView

  on_mount Issho.Live

  alias Issho.State

  @impl true
  def mount(_params, %{"user" => user, "room" => room}, socket) do
    if connected?(socket),
      do: {:ok, _} = Issho.Live.join(IsshoTest.Issho, %{id: user, name: user}, room)

    {:ok,
     socket
     |> assign(:room, room)
     |> State.assign(:retro, room, nil, default: %{"static" => true})}
  end

  @impl true
  def handle_event("add", %{"id" => id, "text" => text} = params, socket) do
    card = %{"id" => id, "text" => text}
    opts = if after_id = params["after"], do: [after: after_id], else: []
    reply(socket, State.change(socket, :retro, [State.insert(["cols", "todo"], card, opts)]))
  end

  def handle_event("vote", %{"id" => id}, socket),
    do:
      reply(
        socket,
        State.change(socket, :retro, [State.increment(["cols", "todo", id, "votes"])])
      )

  def handle_event("done", %{"id" => id}, socket),
    do:
      reply(
        socket,
        State.change(socket, :retro, [State.move(["cols", "todo"], id, to: ["cols", "done"])])
      )

  def handle_event("bad", _params, socket),
    do: reply(socket, State.change(socket, :retro, [State.set([], 1)]))

  defp reply(socket, :ok), do: {:noreply, assign(socket, :error, nil)}
  defp reply(socket, {:error, reason}), do: {:noreply, assign(socket, :error, inspect(reason))}

  @impl true
  def render(assigns) do
    assigns = Map.put_new(assigns, :error, nil)

    ~H"""
    <p :if={@retro["static"]} id="static">static</p>
    <p :if={@error} id="error">{@error}</p>
    <ul :for={col <- ["todo", "done"]} id={col}>
      <li :for={card <- State.get(@retro, ["cols", col]) || []}>
        {card["text"]}:{card["votes"] || 0}
      </li>
    </ul>
    """
  end
end

defmodule IsshoTest.CommentsLive do
  @moduledoc false
  # A page with the room's comments.
  use Phoenix.LiveView

  on_mount Issho.Live

  @impl true
  def mount(_params, %{"user" => user, "room" => room} = session, socket) do
    if connected?(socket),
      do:
        {:ok, _} =
          Issho.Live.join(IsshoTest.Issho, %{id: user, name: session["name"] || user}, room,
            can: session["can"] || :write
          )

    {:ok, assign(socket, room: room)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Issho.Components.comments id="comments" room={@room} mentionable={[%{key: "agent:claude", name: "Claude"}]}>
      <:place :let={%{place: place, default: default}}>
        {if place, do: "Path " <> Enum.join(place["at"]["path"], "."), else: default}
      </:place>
    </Issho.Components.comments>
    """
  end
end
