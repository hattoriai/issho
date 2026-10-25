defmodule Issho.Participant do
  @moduledoc ~S"""
  An actor in a room from Elixir: an agent running in your app, a job, a
  script. It joins like a browser, with the same presence, awareness,
  locks, transactions and policy, and the people in the room see it.

      {:ok, claude} = Issho.join_as(MyApp.Issho, agent, "board:42", on_behalf_of: ada)

      {:ok, doc} = Issho.Participant.open(claude, "board:42")
      Issho.Participant.place(claude, %{"doc" => "board:42", "at" => %{"node" => "n7"}})
      Issho.Participant.lock(claude, [%{"doc" => "board:42", "at" => %{"node" => "n7"}}])
      {:ok, _receipt} = Issho.Participant.transact(claude, "board:42", ops)
      Issho.Participant.leave(claude)

  A participant is a process linked to the one that joins. It forwards
  what happens in the room to that process (or to `:notify`) as
  `{Issho.Participant, participant, event, payload}` messages: `"tx"`,
  `"aware"`, `"presence_diff"` and `"bye"`, as a browser receives them,
  and, with `events: true`, `"event"`: the room's events
  (`Issho.Event`), but those the participant made happen itself.

  `transact/3` takes a list of operations (Issho builds the envelope, on
  the latest revision) or a whole transaction map, to retry one with its
  original id.

  ## Present, paused, stopped

  A participant is a state machine (`:gen_statem`): present in the room,
  or paused or stopped by a person (`Issho.Work`). Paused or stopped, it
  changes nothing: each transaction is refused whole (`{:error,
  {:interrupted, by}}`), so nothing is half done, and its task says who
  paused or stopped it. It reads, looks and leaves as ever. A resume makes
  it present again; so does finishing its task (a pause or a stop), or
  beginning another (a stop).
  """

  @behaviour :gen_statem

  alias Issho.{Authority, Awareness, Identity, Session, Transaction}

  @doc false
  @spec start_link({atom(), Issho.Actor.t(), String.t(), keyword()}) :: :gen_statem.start_ret()
  def start_link({instance, actor, room, opts}) do
    :gen_statem.start_link(
      __MODULE__,
      {instance, actor, room, Keyword.put_new(opts, :notify, self())},
      # A participant with nothing to do for a while takes little memory.
      hibernate_after: 15_000
    )
  end

  @doc "Opens a document of the room; gives its snapshot."
  @spec open(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def open(participant, document_id), do: GenServer.call(participant, {:open, document_id})

  @doc "The document's current snapshot."
  @spec read(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def read(participant, document_id), do: GenServer.call(participant, {:read, document_id})

  @doc """
  Commits operations, or a whole transaction, to an open document.
  Options: `:if_revision`, the version the operations were made on (an
  `Issho.Version` token, as a read gives it): they apply only if the
  document is still at it, or are refused with `{:error, {:stale,
  details}}` (`Issho.Transaction`).
  """
  @spec transact(GenServer.server(), String.t(), [map()] | map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def transact(participant, document_id, ops_or_transaction, opts \\ []),
    do: GenServer.call(participant, {:transact, document_id, ops_or_transaction, opts}, 20_000)

  @doc """
  Whether the room's policy lets the participant do `action` (`:read`,
  `:write`, `:lock` or your own) now: for a component whose data is not
  in Issho's documents, such as a grid of your database, which writes it
  itself. A write needs a participant that writes (`can: :write`).
  """
  @spec authorize(GenServer.server(), atom()) :: :ok | {:error, term()}
  def authorize(participant, action), do: GenServer.call(participant, {:authorize, action})

  @doc "Sets the participant's place (`nil` for none), keeping its locks."
  @spec place(GenServer.server(), map() | nil) :: :ok | {:error, term()}
  def place(participant, place), do: GenServer.call(participant, {:aware, %{"place" => place}})

  @doc "Sets the places the participant locks (`[]` releases them)."
  @spec lock(GenServer.server(), [map()]) :: :ok | {:error, term()}
  def lock(participant, places), do: GenServer.call(participant, {:aware, %{"locks" => places}})

  @doc "Merges keys into the participant's awareness state (`\"status\"`, your own)."
  @spec aware(GenServer.server(), map()) :: :ok | {:error, term()}
  def aware(participant, changes), do: GenServer.call(participant, {:aware, changes})

  @doc """
  Merges a component's own keys into the participant's state, under its
  document (`"blocks"`, see `Issho.Awareness`); a key set to `nil` goes.
  """
  @spec aware_block(GenServer.server(), String.t(), map()) :: :ok | {:error, term()}
  def aware_block(participant, document, changes) when is_binary(document) and is_map(changes),
    do: GenServer.call(participant, {:aware_block, document, changes})

  @doc "The participant's own awareness state: its place, its locks, its status."
  @spec awareness(GenServer.server()) :: map()
  def awareness(participant), do: GenServer.call(participant, :awareness)

  @doc "The participant's key in the room (its identity's)."
  @spec key(GenServer.server()) :: String.t()
  def key(participant), do: GenServer.call(participant, :key)

  @doc "The participant's identity in the room: who it is, and whom it acts for."
  @spec identity(GenServer.server()) :: Identity.t()
  def identity(participant), do: GenServer.call(participant, :identity)

  @doc "The room of the participant."
  @spec room(GenServer.server()) :: String.t()
  def room(participant), do: GenServer.call(participant, :room)

  @doc false
  @spec instance(GenServer.server()) :: atom()
  def instance(participant), do: GenServer.call(participant, :instance)

  @doc """
  Whether someone paused or stopped the participant in the room
  (`Issho.Work`): `%{"action" => "pause" | "stop", "by" => person}`, or
  `nil`. While it is, its transactions are refused.
  """
  @spec interrupted(GenServer.server()) :: map() | nil
  def interrupted(participant), do: GenServer.call(participant, :interrupted)

  @doc false
  # A pause or a stop is over (the participant finished its task), or a
  # stop only (it begins another).
  @spec clear_interrupt(GenServer.server(), [String.t()]) :: :ok
  def clear_interrupt(participant, actions \\ ["pause", "stop"]),
    do: GenServer.call(participant, {:clear_interrupt, actions})

  @doc "The places locked in the room by anyone, each with its holder's key."
  @spec locks(GenServer.server()) :: [{map(), String.t()}]
  def locks(participant), do: GenServer.call(participant, :locks)

  @doc """
  The people of the room now (`Phoenix.Presence`'s list, by actor key),
  each with where they are: `%{key => %{"person" => meta, "places" =>
  [place], "states" => [state]}}`, a place for each of their sessions
  that has one, and each session's whole awareness state (a component's
  own keys: a canvas's selection, say).
  """
  @spec people(GenServer.server()) :: map()
  def people(participant), do: GenServer.call(participant, :people)

  @doc "Leaves the room."
  @spec leave(GenServer.server()) :: :ok
  def leave(participant), do: GenServer.stop(participant, :normal)

  # Server: a state machine of three states, `:present`, `:paused` and
  # `:stopped`. Its data is the session, whom it tells what happens, its own
  # awareness state, and who paused or stopped it.

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init({instance, actor, room, opts}) do
    identity = Identity.new(actor, Keyword.take(opts, [:claims, :on_behalf_of]))
    can = Keyword.get(opts, :can, :write)

    case Session.join(instance, room, identity, can) do
      {:ok, session} ->
        session = if opts[:events], do: Session.listen(session), else: session
        {:ok, :present, %{session: session, notify: opts[:notify], aware: %{}, by: nil}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  # Entering a state: its task, if it has one, says it, for the people.
  def handle_event(:enter, same, same, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, state, data), do: {:keep_state, show(data, state)}

  # Paused or stopped, it changes nothing: whole transactions only, so what
  # it changed before stays.
  def handle_event({:call, from}, {:transact, _document_id, _ops, _opts}, state, data)
      when state in [:paused, :stopped],
      do:
        {:keep_state_and_data,
         {:reply, from, {:error, {:interrupted, interruption(state, data)}}}}

  def handle_event({:call, from}, :interrupted, :present, _data),
    do: {:keep_state_and_data, {:reply, from, nil}}

  def handle_event({:call, from}, :interrupted, state, data),
    do: {:keep_state_and_data, {:reply, from, interruption(state, data)}}

  def handle_event({:call, from}, {:clear_interrupt, actions}, state, data) do
    if state != :present and action(state) in actions,
      do: {:next_state, :present, %{data | by: nil}, {:reply, from, :ok}},
      else: {:keep_state_and_data, {:reply, from, :ok}}
  end

  def handle_event({:call, from}, request, _state, data) do
    {reply, data} = call(request, data)
    {:keep_state, data, {:reply, from, reply}}
  end

  # What happens in the room: forwarded, and a pause, a stop or a resume
  # of this participant is its next state.
  def handle_event(:info, message, _state, data) do
    case Session.handle(data.session, message) do
      {:push, "interrupt", %{"action" => action, "by" => by} = payload, session} ->
        notify(data, "interrupt", payload)
        {:next_state, interrupted_state(action), %{data | session: session, by: by}}

      {:push, event, payload, session} ->
        notify(data, event, payload)
        {:keep_state, %{data | session: session}}

      {:skip, session} ->
        {:keep_state, %{data | session: session}}

      {:stop, reason} ->
        notify(data, "bye", %{"reason" => Atom.to_string(reason)})
        {:stop, :normal}
    end
  end

  # The calls whose answer is the same in every state.
  defp call({:open, document_id}, %{session: session} = data)
       when is_map_key(session.documents, document_id),
       do: {Authority.snapshot(session.documents[document_id]), data}

  defp call({:open, document_id}, data) do
    case Session.open(data.session, document_id) do
      {:ok, snapshot, session} -> {{:ok, snapshot}, %{data | session: session}}
      {:error, _} = error -> {error, data}
    end
  end

  defp call({:read, document_id}, data) do
    case Map.fetch(data.session.documents, document_id) do
      {:ok, pid} -> {Authority.snapshot(pid), data}
      :error -> {{:error, :not_open}, data}
    end
  end

  defp call({:transact, document_id, ops, opts}, data) when is_list(ops) do
    reply =
      with {:ok, pid} <- Map.fetch(data.session.documents, document_id) |> ok_or(:not_open),
           {:ok, transaction} <- Transaction.new(pid, ops, opts) do
        Session.transact(data.session, document_id, transaction)
      end

    {reply, data}
  end

  defp call({:transact, document_id, transaction, _opts}, data) when is_map(transaction),
    do: {Session.transact(data.session, document_id, transaction), data}

  defp call({:aware, changes}, data), do: replace_aware(data, Map.merge(data.aware, changes))

  defp call({:aware_block, document, changes}, data),
    do: replace_aware(data, Issho.Awareness.put_block(data.aware, document, changes))

  defp call(:awareness, data), do: {data.aware, data}
  defp call(:key, data), do: {data.session.identity.key, data}
  defp call(:identity, data), do: {data.session.identity, data}
  defp call(:room, data), do: {data.session.room, data}
  defp call(:instance, data), do: {data.session.instance, data}
  defp call({:authorize, action}, data), do: {Session.authorize(data.session, action), data}
  defp call(:people, data), do: {people_of(data.session), data}

  defp call(:locks, data),
    do: {Awareness.locks(data.session.instance, data.session.room), data}

  defp replace_aware(data, aware) do
    case Session.aware(data.session, aware) do
      {:ok, session} -> {:ok, %{data | session: session, aware: aware}}
      {:error, _} = error -> {error, data}
    end
  end

  defp people_of(session) do
    states =
      session.instance
      |> Awareness.states(session.room)
      |> Enum.reduce(%{}, fn {_session_id, %{"key" => key, "state" => aware}}, acc ->
        if is_map(aware), do: Map.update(acc, key, [aware], &[aware | &1]), else: acc
      end)

    metas = for {key, %{metas: [meta | _]}} <- Session.people(session), into: %{}, do: {key, meta}

    # Everyone the presence knows, and everyone with a state (a room
    # without presence knows no names).
    for key <- Enum.uniq(Map.keys(metas) ++ Map.keys(states)), into: %{} do
      own = Map.get(states, key, [])

      {key,
       %{
         "person" => metas |> Map.get(key, %{"key" => key}) |> Map.delete(:phx_ref),
         "places" => for(%{"place" => place} <- own, place != nil, do: place),
         "states" => own
       }}
    end
  end

  defp interrupted_state("pause"), do: :paused
  defp interrupted_state("stop"), do: :stopped
  defp interrupted_state("resume"), do: :present

  defp action(:paused), do: "pause"
  defp action(:stopped), do: "stop"

  defp interruption(state, data), do: %{"action" => action(state), "by" => data.by}

  # Its task, if it has one, in the state's words, and who paused or
  # stopped it.
  defp show(%{aware: %{"task" => %{} = task}} = data, state) do
    {task_state, by} =
      case state do
        :present -> {"working", nil}
        :paused -> {"paused", data.by}
        :stopped -> {"stopped", data.by}
      end

    case replace_aware(
           data,
           Map.put(data.aware, "task", Map.merge(task, %{"state" => task_state, "by" => by}))
         ) do
      {:ok, data} -> data
      {_error, data} -> data
    end
  end

  defp show(data, _state), do: data

  defp notify(%{notify: nil}, _event, _payload), do: :ok

  # What it made happen itself, it knows.
  defp notify(%{session: %{identity: %{key: key}}}, "event", %Issho.Event{by: %{key: key}}),
    do: :ok

  defp notify(%{notify: pid}, event, payload), do: send(pid, {__MODULE__, self(), event, payload})

  defp ok_or({:ok, value}, _reason), do: {:ok, value}
  defp ok_or(:error, reason), do: {:error, reason}
end
