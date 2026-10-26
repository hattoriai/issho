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

  # A person may ask their own agents: "user:ada" asks "agent:ada-…".
  @impl true
  def ask(identity, _room, "agent:" <> agent) do
    person = String.replace_prefix(identity.key, "user:", "")

    if not denied?(identity.key) and String.starts_with?(agent, person <> "-"),
      do: :ok,
      else: {:error, :forbidden}
  end

  def ask(_identity, _room, _agent), do: {:error, :forbidden}

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

  # A person checks an item: the action an agent runs as a tool.
  def handle_event("check", %{"item" => item, "done" => done} = params, socket) do
    args = %{list: socket.assigns.room, item: item, done: done == "true"}

    message =
      case Issho.Live.act(IsshoTest.CheckItem, args, id: params["id"]) do
        {:ok, receipt} -> "acted:" <> if(receipt.replayed, do: "replayed", else: "ok")
        {:error, reason} -> "acted:" <> Issho.Action.message(reason)
      end

    {:noreply, update(socket, :messages, &[message | &1])}
  end

  # A person retitles the board: the component's action an agent runs too.
  def handle_event("retitle", %{"title" => title}, socket) do
    message =
      case Issho.Live.act(IsshoTest.Retitle, %{board: socket.assigns.room, title: title}) do
        {:ok, _receipt} -> "retitled"
        {:error, reason} -> "retitled:" <> Issho.Action.message(reason)
      end

    {:noreply, update(socket, :messages, &[message | &1])}
  end

  def handle_event("interrupt", %{"agent" => agent, "action" => action}, socket) do
    :ok = Issho.Live.interrupt(socket.assigns.room, agent, String.to_existing_atom(action))
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
        {if place && !place["label"],
          do: "Path " <> Enum.join(place["at"]["path"], "."),
          else: default}
      </:place>
    </Issho.Components.comments>
    """
  end
end

defmodule IsshoTest.OwnInputCommentsLive do
  @moduledoc false
  # Comments written with an input of the app's own, read by the app.
  use Phoenix.LiveView

  on_mount Issho.Live

  @impl true
  def mount(_params, %{"user" => user, "room" => room}, socket) do
    if connected?(socket),
      do: {:ok, _} = Issho.Live.join(IsshoTest.Issho, %{id: user, name: user}, room)

    {:ok, assign(socket, room: room)}
  end

  # The app's input says its words in capitals, and whom it mentions itself.
  def read(%{"body" => body}), do: %{body: String.upcase(body), mentions: ["user:ken"]}

  @impl true
  def render(assigns) do
    ~H"""
    <Issho.Components.comments id="comments" room={@room} read={&__MODULE__.read/1}>
      <:input :let={input}>
        <input class="own-input" id={input.field.id} name={input.field.name} value={input.value} />
      </:input>
    </Issho.Components.comments>
    """
  end
end

defmodule IsshoTest.StreamsLive do
  @moduledoc false
  # A page with the room's streams it may see, as they come; Accept
  # closes one.
  use Phoenix.LiveView

  on_mount Issho.Live

  @impl true
  def mount(_params, %{"user" => user, "room" => room}, socket) do
    streams =
      if connected?(socket) do
        {:ok, _} = Issho.Live.join(IsshoTest.Issho, %{id: user, name: user}, room)
        {:ok, streams} = Issho.Live.streams(room)
        streams
      else
        []
      end

    {:ok, assign(socket, room: room, outputs: Map.new(streams, &{&1.id, &1}), closed: nil)}
  end

  @impl true
  def handle_info({Issho, :stream, id, message}, socket),
    do: {:noreply, update(socket, :outputs, &heard(&1, id, message))}

  @impl true
  def handle_event("accept", %{"id" => id}, socket) do
    result = Issho.Live.close_stream(socket.assigns.room, id, :accepted)
    {:noreply, assign(socket, :closed, inspect(result))}
  end

  defp heard(streams, _id, {:started, stream}), do: Map.put(streams, stream.id, stream)

  defp heard(streams, id, {:chunk, text}),
    do: Map.update!(streams, id, &%{&1 | content: &1.content <> text})

  defp heard(streams, id, :finished), do: Map.update!(streams, id, &%{&1 | state: :finished})
  defp heard(streams, id, {:closed, _outcome}), do: Map.delete(streams, id)
  defp heard(streams, id, :gone), do: Map.delete(streams, id)
  defp heard(streams, _id, _other), do: streams

  @impl true
  def render(assigns) do
    ~H"""
    <p id="closed">{@closed}</p>
    <article :for={{id, stream} <- @outputs} id={"stream-" <> id} data-state={stream.state}>
      {stream.content}
      <button phx-click="accept" phx-value-id={id}>Accept</button>
    </article>
    """
  end
end

defmodule IsshoTest.CheckItem do
  @moduledoc false
  # The test app's action: an item of a checklist, the app's own data (an
  # Agent), checked by a person's button or an agent's tool. "archived:"
  # items may not change (the app's invariant), "broken" fails, and "slow"
  # waits for the test's :go.
  use Issho.Action,
    name: "check_item",
    description: "Checks or unchecks an item of the room's checklist."

  arg :list, :string, required: true, description: "The checklist's room."
  arg :item, :string, required: true, max_length: 80
  arg :done, :boolean, required: true

  @impl Issho.Action
  def target(%{list: list}), do: list

  @impl Issho.Action
  def authorize(%{item: "archived:" <> _}, _who), do: {:error, "That item is archived."}
  def authorize(_args, _who), do: :ok

  @impl Issho.Action
  def run(%{item: "broken"}, _invocation), do: {:error, "That item is broken."}

  def run(%{list: list, item: item, done: done}, invocation) do
    if item == "slow" do
      send(:persistent_term.get({__MODULE__, :waiter}), {:running, self()})
      receive do: (:go -> :ok)
    end

    Agent.update(IsshoTest.Checklist, fn lists ->
      Map.update(lists, {list, item}, %{done: done, by: invocation.by.key, runs: 1}, fn entry ->
        %{entry | done: done, by: invocation.by.key, runs: entry.runs + 1}
      end)
    end)

    {:ok, %{item: item, done: done}}
  end

  @impl Issho.Action
  def summary(%{item: item, done: true}), do: "Checked #{item}."
  def summary(%{item: item, done: false}), do: "Unchecked #{item}."

  @impl Issho.Action
  def event(%{item: item, done: done}, _result), do: %{item: item, done: done}

  def entry(list, item), do: Agent.get(IsshoTest.Checklist, &Map.get(&1, {list, item}))
end

defmodule IsshoTest.Retitle do
  @moduledoc false
  # A component's action: the board document's title, changed as whoever
  # runs it. An agent goes to the title first (its gesture), and waits
  # there for the test's :go when it is told to (a :waiter).
  use Issho.Action,
    name: "retitle_board",
    description: "Changes a board's title."

  arg :board, :string, required: true
  arg :title, :string, required: true, max_length: 120

  @impl Issho.Action
  def target(%{board: board}), do: Issho.Policy.room(board)

  @impl Issho.Action
  def gesture(%{board: board}, invocation) do
    :ok =
      Issho.Participant.place(invocation.participant, %{
        "doc" => board,
        "at" => %{"path" => ["title"]}
      })

    case :persistent_term.get({__MODULE__, :waiter}, nil) do
      nil ->
        :ok

      waiter ->
        send(waiter, {:on_the_way, self()})
        receive do: (:go -> :ok)
    end
  end

  @impl Issho.Action
  def run(%{board: board, title: title}, invocation) do
    with {:ok, %{"state" => state}} <- Issho.Action.read(invocation, board),
         true <- state["title"] != title || {:error, "It is already #{inspect(title)}."},
         do:
           Issho.Action.transact(invocation, board, [
             %{"op" => "set", "path" => ["title"], "value" => title}
           ])
  end

  @impl Issho.Action
  def offer("canvas:" <> _, _who), do: {:error, "A canvas has no title."}
  def offer(_room, _who), do: :ok

  @impl Issho.Action
  def summary(_receipt), do: "Retitled."
end
