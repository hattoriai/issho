defmodule Issho.Awareness do
  @moduledoc """
  Where the people of a room are, and what they are doing: their places,
  selections, drags and locks, many times a second.

  Awareness is ephemeral by design: never saved, never replicated by
  `Phoenix.Presence`'s CRDT, and only the latest state of each session
  matters. A room has one awareness process on each node where it has
  sessions. Each one:

    * keeps the latest state of each local session (`put/5`);
    * every `:awareness_interval` (50 ms), sends one frame with the states
      that changed, to the room's sessions on every node, so that each
      session receives about 20 frames a second whatever the size of the
      room, instead of a message from every other person on every move;
    * sends every state now and then (`:awareness_full_every` frames, 5
      seconds), and when another node's awareness of the room starts, so
      that a session that missed a frame, or joined late, catches up;
    * forgets a session when its process stops, and a node it stopped
      hearing from;
    * keeps the room's whole picture from every node's frames, for
      `states/2` and `locks/2` (agents that look before they act).

  It stops when its node has no session left in the room.

  A state is a map of the binding's choosing; Issho reads `"place"` (an
  `Issho.Place`), `"locks"` (a list of places) and `"status"`.
  """

  use GenServer, restart: :temporary

  alias Issho.Config

  @doc false
  def start_link({instance, room}) do
    GenServer.start_link(__MODULE__, {instance, room}, name: via(instance, room))
  end

  @doc false
  def child_spec({instance, room}) do
    %{
      id: {__MODULE__, room},
      start: {__MODULE__, :start_link, [{instance, room}]},
      restart: :temporary
    }
  end

  @doc false
  @spec topic(String.t()) :: String.t()
  def topic(room), do: "issho:awareness:" <> room

  @doc """
  Sets the state of a session (a channel or an agent process, `pid`) in
  the room, for the actor `key`. `nil` clears it.
  """
  @spec put(atom(), String.t(), String.t(), map() | nil, pid()) :: :ok
  def put(instance, room, key, state, pid \\ self()) do
    GenServer.cast(ensure(instance, room), {:put, pid, key, state})
  end

  @doc """
  The states of the room, from every node: `%{session_id => %{"key" =>
  actor_key, "state" => state}}`.
  """
  @spec states(atom(), String.t()) :: map()
  def states(instance, room), do: GenServer.call(ensure(instance, room), :states)

  @doc "The places locked in the room, each with the key of the actor that holds it."
  @spec locks(atom(), String.t()) :: [{term(), String.t()}]
  def locks(instance, room) do
    for {_session, %{"key" => key, "state" => %{"locks" => locks}}} <- states(instance, room),
        is_list(locks),
        place <- locks,
        do: {place, key}
  end

  @doc "The session id of a process, as frames name it."
  @spec session_id(pid()) :: String.t()
  def session_id(pid) do
    pid
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:md5, &1))
    |> Base.url_encode64(padding: false)
  end

  @doc false
  @spec ensure(atom(), String.t()) :: pid()
  def ensure(instance, room) do
    case Registry.lookup(Config.child_name(instance, AwarenessRegistry), room) do
      [{pid, _}] ->
        pid

      [] ->
        supervisor = Config.child_name(instance, AwarenessSupervisor)

        case DynamicSupervisor.start_child(supervisor, {__MODULE__, {instance, room}}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defp via(instance, room),
    do: {:via, Registry, {Config.child_name(instance, AwarenessRegistry), room}}

  # Server

  @impl true
  def init({instance, room}) do
    config = Config.get(instance)
    :ok = Phoenix.PubSub.subscribe(config.pubsub, topic(room))

    Phoenix.PubSub.broadcast_from(
      config.pubsub,
      self(),
      topic(room),
      {Issho, :awareness_hello, room}
    )

    {:ok,
     %{
       config: config,
       room: room,
       node: Atom.to_string(node()),
       local: %{},
       pids: %{},
       dirty: MapSet.new(),
       gone: MapSet.new(),
       remote: %{},
       frames: 0,
       full_next: false,
       timer: nil
     }}
  end

  @impl true
  def handle_cast({:put, pid, _key, nil}, state) do
    session = session_id(pid)

    case Map.pop(state.local, session) do
      {nil, _} -> {:noreply, state}
      {_entry, local} -> {:noreply, forget(%{state | local: local}, session)}
    end
  end

  def handle_cast({:put, pid, key, value}, state) do
    session = session_id(pid)

    pids =
      if Map.has_key?(state.pids, pid) do
        state.pids
      else
        Process.monitor(pid)
        Map.put(state.pids, pid, session)
      end

    {:noreply,
     schedule(%{
       state
       | local: Map.put(state.local, session, %{"key" => key, "state" => value}),
         pids: pids,
         dirty: MapSet.put(state.dirty, session),
         gone: MapSet.delete(state.gone, session)
     })}
  end

  @impl true
  def handle_call(:states, _from, state) do
    remote = state.remote |> Map.values() |> Enum.reduce(%{}, &Map.merge(&2, &1.states))
    {:reply, Map.merge(remote, state.local), state}
  end

  @impl true
  def handle_info(:tick, state) do
    frames = state.frames + 1
    full? = state.full_next or rem(frames, state.config.awareness_full_every) == 0
    changed = if full?, do: Map.keys(state.local), else: MapSet.to_list(state.dirty)

    if changed != [] or MapSet.size(state.gone) > 0 do
      frame = %{
        "node" => state.node,
        "full" => full?,
        "states" => Map.take(state.local, changed),
        "gone" => MapSet.to_list(state.gone)
      }

      # To every other process on the topic: the sessions of the room on
      # every node, and the other nodes' awareness of the room.
      message = {Issho, :awareness, state.room, frame}
      Phoenix.PubSub.broadcast_from(state.config.pubsub, self(), topic(state.room), message)
    end

    state = %{
      prune(state)
      | dirty: MapSet.new(),
        gone: MapSet.new(),
        frames: frames,
        full_next: false,
        timer: nil
    }

    if map_size(state.local) == 0, do: {:stop, :normal, state}, else: {:noreply, schedule(state)}
  end

  # Another node's frame: its sessions' states, for states/2, and for this
  # node's sessions, which get it from the PubSub themselves.
  def handle_info({Issho, :awareness, _room, %{"node" => node} = frame}, state) do
    states =
      if frame["full"],
        do: frame["states"],
        else:
          state.remote
          |> Map.get(node, %{states: %{}})
          |> Map.get(:states)
          |> Map.merge(frame["states"])

    entry = %{states: Map.drop(states, frame["gone"]), seen: System.monotonic_time(:millisecond)}
    {:noreply, %{state | remote: Map.put(state.remote, node, entry)}}
  end

  def handle_info({Issho, :awareness_hello, _room}, state),
    do: {:noreply, schedule(%{state | full_next: true})}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {session, pids} = Map.pop(state.pids, pid)
    state = %{state | pids: pids}

    case session && Map.pop(state.local, session) do
      {entry, local} when entry != nil -> {:noreply, forget(%{state | local: local}, session)}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp forget(state, session) do
    schedule(%{
      state
      | dirty: MapSet.delete(state.dirty, session),
        gone: MapSet.put(state.gone, session)
    })
  end

  # A node that has sent nothing for three full intervals is gone.
  defp prune(state) do
    limit = 3 * state.config.awareness_full_every * state.config.awareness_interval
    now = System.monotonic_time(:millisecond)
    %{state | remote: Map.reject(state.remote, fn {_node, entry} -> now - entry.seen > limit end)}
  end

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :tick, state.config.awareness_interval)}

  defp schedule(state), do: state
end
