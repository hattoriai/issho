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
  `"aware"`, `"presence_diff"` and `"bye"`, as a browser receives them.

  `transact/3` takes a list of operations (Issho builds the envelope, on
  the latest revision) or a whole transaction map, to retry one with its
  original id.
  """

  use GenServer

  alias Issho.{Authority, Awareness, Identity, Session, Transaction}

  @doc false
  @spec start_link({atom(), Issho.Actor.t(), String.t(), keyword()}) :: GenServer.on_start()
  def start_link({instance, actor, room, opts}) do
    GenServer.start_link(
      __MODULE__,
      {instance, actor, room, Keyword.put_new(opts, :notify, self())}
    )
  end

  @doc "Opens a document of the room; gives its snapshot."
  @spec open(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def open(participant, document_id), do: GenServer.call(participant, {:open, document_id})

  @doc "The document's current snapshot."
  @spec read(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def read(participant, document_id), do: GenServer.call(participant, {:read, document_id})

  @doc "Commits operations, or a whole transaction, to an open document."
  @spec transact(GenServer.server(), String.t(), [map()] | map()) ::
          {:ok, map()} | {:error, term()}
  def transact(participant, document_id, ops_or_transaction),
    do: GenServer.call(participant, {:transact, document_id, ops_or_transaction}, 20_000)

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

  @doc "The participant's own awareness state: its place, its locks, its status."
  @spec awareness(GenServer.server()) :: map()
  def awareness(participant), do: GenServer.call(participant, :awareness)

  @doc "The participant's key in the room (its identity's)."
  @spec key(GenServer.server()) :: String.t()
  def key(participant), do: GenServer.call(participant, :key)

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

  # Server

  @impl true
  def init({instance, actor, room, opts}) do
    identity = Identity.new(actor, Keyword.take(opts, [:claims, :on_behalf_of]))
    can = Keyword.get(opts, :can, :write)

    case Session.join(instance, room, identity, can) do
      {:ok, session} -> {:ok, %{session: session, notify: opts[:notify], aware: %{}}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:open, document_id}, _from, %{session: session} = state)
      when is_map_key(session.documents, document_id),
      do: {:reply, Authority.snapshot(session.documents[document_id]), state}

  def handle_call({:open, document_id}, _from, state) do
    case Session.open(state.session, document_id) do
      {:ok, snapshot, session} -> {:reply, {:ok, snapshot}, %{state | session: session}}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:read, document_id}, _from, state) do
    case Map.fetch(state.session.documents, document_id) do
      {:ok, pid} -> {:reply, Authority.snapshot(pid), state}
      :error -> {:reply, {:error, :not_open}, state}
    end
  end

  def handle_call({:transact, document_id, ops}, _from, state) when is_list(ops) do
    reply =
      with {:ok, pid} <- Map.fetch(state.session.documents, document_id) |> ok_or(:not_open),
           {:ok, snapshot} <- Authority.snapshot(pid) do
        transaction = %{
          "id" => Transaction.id(),
          "epoch" => snapshot["epoch"],
          "base_revision" => snapshot["revision"],
          "ops" => ops
        }

        Session.transact(state.session, document_id, transaction)
      end

    {:reply, reply, state}
  end

  def handle_call({:transact, document_id, transaction}, _from, state) when is_map(transaction),
    do: {:reply, Session.transact(state.session, document_id, transaction), state}

  def handle_call({:aware, changes}, _from, state) do
    aware = Map.merge(state.aware, changes)

    case Session.aware(state.session, aware) do
      {:ok, session} -> {:reply, :ok, %{state | session: session, aware: aware}}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:awareness, _from, state), do: {:reply, state.aware, state}

  def handle_call(:key, _from, state), do: {:reply, state.session.identity.key, state}

  def handle_call({:authorize, action}, _from, state),
    do: {:reply, Session.authorize(state.session, action), state}

  def handle_call(:people, _from, %{session: session} = state) do
    states =
      session.instance
      |> Awareness.states(session.room)
      |> Enum.reduce(%{}, fn {_session_id, %{"key" => key, "state" => aware}}, acc ->
        if is_map(aware), do: Map.update(acc, key, [aware], &[aware | &1]), else: acc
      end)

    metas = for {key, %{metas: [meta | _]}} <- Session.people(session), into: %{}, do: {key, meta}

    # Everyone the presence knows, and everyone with a state (a room
    # without presence knows no names).
    people =
      for key <- Enum.uniq(Map.keys(metas) ++ Map.keys(states)), into: %{} do
        own = Map.get(states, key, [])

        {key,
         %{
           "person" => metas |> Map.get(key, %{"key" => key}) |> Map.delete(:phx_ref),
           "places" => for(%{"place" => place} <- own, place != nil, do: place),
           "states" => own
         }}
      end

    {:reply, people, state}
  end

  def handle_call(:locks, _from, state),
    do: {:reply, Awareness.locks(state.session.instance, state.session.room), state}

  @impl true
  def handle_info(message, state) do
    case Session.handle(state.session, message) do
      {:push, event, payload, session} ->
        notify(state, event, payload)
        {:noreply, %{state | session: session}}

      {:skip, session} ->
        {:noreply, %{state | session: session}}

      {:stop, reason} ->
        notify(state, "bye", %{"reason" => Atom.to_string(reason)})
        {:stop, :normal, state}
    end
  end

  defp notify(%{notify: nil}, _event, _payload), do: :ok
  defp notify(%{notify: pid}, event, payload), do: send(pid, {__MODULE__, self(), event, payload})

  defp ok_or({:ok, value}, _reason), do: {:ok, value}
  defp ok_or(:error, reason), do: {:error, reason}
end
