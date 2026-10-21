defmodule IsshoTest.Policy do
  @moduledoc false
  # The test app's policy: rooms "board:*" are maps; an actor whose key is
  # in the denied set may do nothing, and "readonly:*" rooms refuse :write.
  @behaviour Issho.Policy

  def deny(key), do: :persistent_term.put({__MODULE__, key}, true)
  def allow(key), do: :persistent_term.erase({__MODULE__, key})
  defp denied?(key), do: :persistent_term.get({__MODULE__, key}, false)

  @impl true
  def authorize(identity, room, action) do
    cond do
      denied?(identity.key) -> {:error, :forbidden}
      String.starts_with?(room, "readonly:") and action in [:write, :lock] -> {:error, :forbidden}
      true -> :ok
    end
  end

  @impl true
  def document(_identity, "missing:" <> _), do: {:error, :not_found}

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

  @impl true
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
