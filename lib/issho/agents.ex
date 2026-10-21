defmodule Issho.Agents do
  @moduledoc ~S"""
  Agents in rooms for front ends without a lasting connection: an MCP
  server, whose every tool call is its own request, a webhook, a chat
  bot. An agent joins a room on its first call and stays, present and
  where it last pointed, between calls; it leaves after `:idle`
  milliseconds with no call (ten minutes), or when told.

      {:ok, claude} = Issho.Agents.join(MyApp.Issho, agent, "board:42", on_behalf_of: ada)
      {:ok, _snapshot} = Issho.Participant.open(claude, "board:42")
      Issho.Participant.place(claude, %{"doc" => "board:42", "at" => %{"node" => "n7"}})

  `join/4` gives the agent's `Issho.Participant`, the same one each time
  for the same actor and room, and starts the idle time again. People
  see the agent as they see anyone: its name, its place, its changes.

  The agents of a node are found on that node; an MCP endpoint behind a
  load balancer needs session affinity, or one node for its agents.
  """

  use GenServer

  alias Issho.{Config, Identity}

  @idle 600_000

  @doc """
  The agent's participant in the room, joining it on the first call.
  Options: those of `Issho.join_as/4` (`:can`, `:on_behalf_of`,
  `:claims`) and `:idle`.
  """
  @spec join(atom(), Issho.Actor.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def join(instance, actor, room, opts \\ []) do
    key = Identity.new(actor).key

    case whereis(instance, key, room) do
      nil -> start(instance, actor, room, opts)
      agent -> GenServer.call(agent, :touch)
    end
  end

  @doc "The participant of the agent with this key in the room, if it is there."
  @spec participant(atom(), String.t(), String.t()) :: pid() | nil
  def participant(instance, key, room) do
    case call(instance, key, room, :touch, nil) do
      {:ok, participant} -> participant
      nil -> nil
    end
  end

  @doc """
  Keeps a value for the agent in the room, for its later calls (what it
  copied, what it was asked to remember), until it leaves.
  """
  @spec put(atom(), String.t(), String.t(), term(), term()) :: :ok | {:error, :not_there}
  def put(instance, key, room, name, value),
    do: call(instance, key, room, {:put, name, value}, {:error, :not_there})

  @doc "A value the agent kept in the room, or `default`."
  @spec get(atom(), String.t(), String.t(), term(), term()) :: term()
  def get(instance, key, room, name, default \\ nil),
    do: call(instance, key, room, {:get, name, default}, default)

  @doc "Takes the agent out of the room."
  @spec leave(atom(), String.t(), String.t()) :: :ok
  def leave(instance, key, room) do
    case whereis(instance, key, room) do
      nil -> :ok
      agent -> GenServer.stop(agent, :normal)
    end
  catch
    :exit, _reason -> :ok
  end

  @doc "The rooms the agent with this key is in, on this node."
  @spec rooms(atom(), String.t()) :: [String.t()]
  def rooms(instance, key) do
    Registry.select(Config.child_name(instance, AgentRegistry), [
      {{{key, :"$1"}, :_, :_}, [], [:"$1"]}
    ])
  end

  # A call to the agent, or `gone` when it is not there: one that just left
  # can still be registered for a moment after it ended.
  defp call(instance, key, room, message, gone) do
    case whereis(instance, key, room) do
      nil -> gone
      agent -> GenServer.call(agent, message)
    end
  catch
    :exit, _reason -> gone
  end

  defp whereis(instance, key, room) do
    case Registry.lookup(Config.child_name(instance, AgentRegistry), {key, room}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp start(instance, actor, room, opts) do
    key = Identity.new(actor).key
    name = {:via, Registry, {Config.child_name(instance, AgentRegistry), {key, room}}}

    spec = %{
      id: __MODULE__,
      start: {GenServer, :start_link, [__MODULE__, {instance, actor, room, opts}, [name: name]]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(Config.child_name(instance, Agents), spec) do
      {:ok, agent} -> GenServer.call(agent, :touch)
      {:error, {:already_started, agent}} -> GenServer.call(agent, :touch)
      {:error, reason} -> {:error, reason}
    end
  end

  # Server

  @impl true
  def init({instance, actor, room, opts}) do
    join_opts =
      opts |> Keyword.take([:can, :on_behalf_of, :claims]) |> Keyword.put(:notify, self())

    case Issho.join_as(instance, actor, room, join_opts) do
      {:ok, participant} ->
        Process.link(participant)
        idle = Keyword.get(opts, :idle, @idle)
        {:ok, %{participant: participant, idle: idle, timer: timer(nil, idle), memory: %{}}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:touch, _from, state),
    do: {:reply, {:ok, state.participant}, %{state | timer: timer(state.timer, state.idle)}}

  def handle_call({:put, name, value}, _from, state),
    do: {:reply, :ok, %{state | memory: Map.put(state.memory, name, value)}}

  def handle_call({:get, name, default}, _from, state),
    do: {:reply, Map.get(state.memory, name, default), state}

  @impl true
  def handle_info(:idle, state), do: {:stop, :normal, state}

  # The room ended the session (revoked, refused): the agent goes too.
  def handle_info({Issho.Participant, _participant, "bye", _payload}, state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.participant), do: Issho.Participant.leave(state.participant)
  catch
    :exit, _reason -> :ok
  end

  defp timer(previous, idle) do
    if previous, do: Process.cancel_timer(previous)
    Process.send_after(self(), :idle, idle)
  end
end
