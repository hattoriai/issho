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

  An agent in a room hears its events (`Issho.Event`), but those it made
  happen itself, and keeps the last 100 of them until it takes them
  (`wait/5`, the `wait_for_events` tool): what people did between its
  calls, and what it waits for (someone mentions it, a document changes).

  An agent is one in the cluster (`:global`, as the documents'
  authorities are): a call on any node finds it, so an MCP endpoint
  behind a load balancer needs no session affinity.

  ## Its work

  Your app's own agent (a model your app calls, not an MCP client) can
  run its work under Issho: `run/5` runs a function as the agent, in a
  process linked to it. When a person stops the agent (`Issho.Work`), the
  process is ended at once, wherever it is (waiting on the model, in the
  middle of a tool), not at its next change; a pause still lets it run,
  and refuses its changes. When it crashes, its task says it failed and
  the room hears `"agent.failed"` (`Issho.Work.failed/2`).

  Each agent in a room is a state machine (`:gen_statem`): listening, or
  waiting (a call of `wait/6` that has nothing yet), with its idle time
  and a wait's time as its timeouts. An agent idle for a while
  hibernates: it takes little memory until it is called.
  """

  @behaviour :gen_statem

  require Logger

  alias Issho.{Config, Identity}

  @idle 600_000
  # An agent with nothing to do for this long hibernates.
  @hibernate_after 15_000
  # The events an agent keeps until it takes them.
  @kept 100

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

  @doc """
  The events of the room since the agent last took them, whose names are
  one of `names` (`Issho.Events.match?/2`: a list of names, `"kind.*"`, or
  `:all`), oldest first; when there is none yet, waits up to `timeout`
  milliseconds for one. With `mentions_me: true`, only those whose data
  mentions the agent (`mentions`, a comment's). Gives `{:ok, events}`, an empty list when none
  came, or `{:error, :not_there}` for an agent not in the room.
  """
  @spec wait(atom(), String.t(), String.t(), :all | [String.t()], non_neg_integer(), keyword()) ::
          {:ok, [Issho.Event.t()]} | {:error, :not_there}
  def wait(instance, key, room, names, timeout, opts \\ [])
      when is_integer(timeout) and timeout >= 0 do
    wanted = {names, if(opts[:mentions_me], do: key)}
    call(instance, key, room, {:wait, wanted, timeout}, {:error, :not_there}, timeout + 5_000)
  end

  @doc """
  Runs the agent's work in the room, joining it as `join/4` does: `fun`,
  given the agent's participant, in a process linked to the agent, which
  stays in the room while it runs (its idle time starts when the work
  ends). One work at a time: `{:error, :running}` while one runs.

      {:ok, work} =
        Issho.Agents.run(MyApp.Issho, assistant, "board:42", fn claude ->
          :ok = Issho.Work.start(claude, "Group the cards", ["Read", "Group"])
          # ... the model, the tools ...
          Issho.Work.finish(claude, "Grouped 14 cards.")
        end, on_behalf_of: ada)

  Gives `{:ok, pid}`. Monitor it to know how it ended: `:normal`;
  `{:shutdown, {:stopped, by}}`, a person stopped the agent (`by`, who);
  `{:shutdown, :left}`, the agent left the room; or the reason it
  crashed, when the agent's task says it failed (`Issho.Work.failed/2`).
  """
  @spec run(atom(), Issho.Actor.t(), String.t(), (pid() -> term()), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def run(instance, actor, room, fun, opts \\ []) when is_function(fun, 1) do
    with {:ok, _participant} <- join(instance, actor, room, opts),
         do: call(instance, Identity.new(actor).key, room, {:run, fun}, {:error, :not_there})
  end

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

  @doc "The rooms the agent with this key is in, in the cluster."
  @spec rooms(atom(), String.t()) :: [String.t()]
  def rooms(instance, key) do
    for {__MODULE__, ^instance, ^key, room} <- :global.registered_names(), do: room
  end

  # A call to the agent, or `gone` when it is not there: one that just left
  # can still be registered for a moment after it ended.
  defp call(instance, key, room, message, gone, timeout \\ 5_000) do
    case whereis(instance, key, room) do
      nil -> gone
      agent -> GenServer.call(agent, message, timeout)
    end
  catch
    :exit, _reason -> gone
  end

  @doc false
  # The agent's process, on any node.
  @spec whereis(atom(), String.t(), String.t()) :: pid() | nil
  def whereis(instance, key, room) do
    case :global.whereis_name(name(instance, key, room)) do
      pid when is_pid(pid) -> pid
      :undefined -> nil
    end
  end

  defp name(instance, key, room), do: {__MODULE__, instance, key, room}

  # Registered as it starts, in the whole cluster at once: two nodes that
  # start the same agent together have one, and the other gets it.
  defp start(instance, actor, room, opts) do
    key = Identity.new(actor).key

    spec = %{
      id: __MODULE__,
      start:
        {:gen_statem, :start_link,
         [
           {:global, name(instance, key, room)},
           __MODULE__,
           {instance, actor, room, opts},
           [hibernate_after: @hibernate_after]
         ]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(Config.child_name(instance, Agents), spec) do
      {:ok, agent} -> GenServer.call(agent, :touch)
      {:error, {:already_started, agent}} -> GenServer.call(agent, :touch)
      {:error, reason} -> {:error, reason}
    end
  end

  # Server: a state machine of two states, `:listening` and `{:waiting,
  # from, wanted}`, a caller waiting for an event it wants. Its data is its
  # participant, its idle time, what it remembers, the events it keeps
  # until it takes them, and its work, while one runs. Its idle time is a
  # timeout that every call starts again, but while its work runs; a
  # wait's time is another. It traps exits: its participant's and its
  # work's end are messages to it.

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init({instance, actor, room, opts}) do
    join_opts =
      opts
      |> Keyword.take([:can, :on_behalf_of, :claims])
      |> Keyword.merge(notify: self(), events: true)

    Process.flag(:trap_exit, true)

    case Issho.join_as(instance, actor, room, join_opts) do
      {:ok, participant} ->
        Process.link(participant)
        idle = Keyword.get(opts, :idle, @idle)

        data = %{
          participant: participant,
          key: Identity.new(actor).key,
          room: room,
          idle: idle,
          memory: %{},
          events: [],
          work: nil
        }

        {:ok, :listening, data, idle_timeout(data)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_event({:call, from}, :touch, _state, data),
    do: {:keep_state_and_data, [{:reply, from, {:ok, data.participant}}, idle_timeout(data)]}

  def handle_event({:call, from}, {:put, name, value}, _state, data),
    do:
      {:keep_state, %{data | memory: Map.put(data.memory, name, value)},
       [{:reply, from, :ok}, idle_timeout(data)]}

  def handle_event({:call, from}, {:get, name, default}, _state, data),
    do:
      {:keep_state_and_data,
       [{:reply, from, Map.get(data.memory, name, default)}, idle_timeout(data)]}

  # The events kept that it wants, or a wait for the next one. A wait
  # before is answered, empty: an agent waits once at a time.
  def handle_event({:call, from}, {:wait, wanted, timeout}, state, data) do
    answered = answer(state, [])

    case take(data.events, wanted) do
      {[], _events} ->
        {:next_state, {:waiting, from, wanted}, data,
         answered ++ [{{:timeout, :wait}, timeout, :waited}, idle_timeout(data)]}

      {events, rest} ->
        {:next_state, :listening, %{data | events: rest},
         answered ++ [{:reply, from, {:ok, events}}, cancel_wait(), idle_timeout(data)]}
    end
  end

  def handle_event(:info, {Issho.Participant, _participant, "event", event}, state, data) do
    case state do
      {:waiting, from, wanted} ->
        if wanted?(wanted, event),
          do: {:next_state, :listening, data, [{:reply, from, {:ok, [event]}}, cancel_wait()]},
          else: {:keep_state, keep(data, event)}

      :listening ->
        {:keep_state, keep(data, event)}
    end
  end

  def handle_event({:timeout, :wait}, :waited, state, data),
    do: {:next_state, :listening, data, answer(state, [])}

  def handle_event({:call, from}, {:run, _fun}, _state, %{work: work}) when is_pid(work),
    do: {:keep_state_and_data, {:reply, from, {:error, :running}}}

  def handle_event({:call, from}, {:run, fun}, _state, data) do
    participant = data.participant
    work = spawn_link(fn -> fun.(participant) end)
    data = %{data | work: work}
    {:keep_state, data, [{:reply, from, {:ok, work}}, idle_timeout(data)]}
  end

  # Stopped by a person: its work ends now, wherever it is.
  def handle_event(
        :info,
        {Issho.Participant, _participant, "interrupt", %{"action" => "stop", "by" => by}},
        _state,
        %{work: work}
      )
      when is_pid(work) do
    Process.exit(work, {:shutdown, {:stopped, by}})
    :keep_state_and_data
  end

  def handle_event(:info, {:EXIT, work, reason}, _state, %{work: work} = data) do
    unless ended?(reason) do
      # In the app's log: OTP's own report of it is one Elixir leaves out.
      Logger.error(
        "Issho: the work of #{data.key} in #{data.room} crashed: " <>
          Exception.format_exit(reason)
      )

      Issho.Work.failed(data.participant, reason)
    end

    data = %{data | work: nil}
    {:keep_state, data, idle_timeout(data)}
  end

  # Its participant is gone: the agent has no place in the room.
  def handle_event(:info, {:EXIT, participant, _reason}, _state, %{participant: participant}),
    do: {:stop, :normal}

  def handle_event({:timeout, :idle}, :idle, _state, _data), do: {:stop, :normal}

  # The room ended the session (revoked, refused): the agent goes too.
  def handle_event(:info, {Issho.Participant, _participant, "bye", _payload}, _state, _data),
    do: {:stop, :normal}

  def handle_event(:info, _message, _state, _data), do: :keep_state_and_data

  @impl true
  def terminate(_reason, _state, data) do
    if data.work, do: Process.exit(data.work, {:shutdown, :left})
    if Process.alive?(data.participant), do: Issho.Participant.leave(data.participant)
  catch
    :exit, _reason -> :ok
  end

  # How a work may end, but crashing.
  defp ended?(:normal), do: true
  defp ended?(:shutdown), do: true
  defp ended?({:shutdown, _reason}), do: true
  defp ended?(_reason), do: false

  # No idle time while its work runs.
  defp idle_timeout(%{work: work}) when is_pid(work), do: {{:timeout, :idle}, :cancel}
  defp idle_timeout(data), do: {{:timeout, :idle}, data.idle, :idle}
  defp cancel_wait, do: {{:timeout, :wait}, :cancel}

  # The caller waiting, if one is, answered with these events.
  defp answer({:waiting, from, _wanted}, events), do: [{:reply, from, {:ok, events}}]
  defp answer(:listening, _events), do: []

  defp keep(data, event),
    do: %{data | events: Enum.take(data.events ++ [event], -@kept)}

  defp take(events, wanted), do: Enum.split_with(events, &wanted?(wanted, &1))

  defp wanted?({names, nil}, event), do: Issho.Events.match?(names, event.name)

  defp wanted?({names, key}, event),
    do: Issho.Events.match?(names, event.name) and key in List.wrap(event.data[:mentions])
end
