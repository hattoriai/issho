defmodule Issho.Session do
  @moduledoc false
  # One actor's presence in one room, the same for a browser's channel
  # (Issho.Channel) and an agent's process (Issho.Participant): joining,
  # opening the room's documents, transactions, awareness, and the checks
  # in both directions. The functions run in the session's own process.

  alias Issho.{
    Authority,
    Awareness,
    Config,
    Documents,
    Event,
    Events,
    Identity,
    Place,
    Policy,
    Presence
  }

  # How often, at most, the policy is asked again before an awareness frame
  # goes out. Changes to documents are checked every time.
  @recheck_ms 1_000

  defstruct [
    :instance,
    :room,
    :identity,
    :can,
    :session_id,
    documents: %{},
    places: %{},
    place: nil,
    events: false,
    checked_at: nil
  ]

  @type t :: %__MODULE__{}

  @spec join(atom(), String.t(), Identity.t(), :read | :write) :: {:ok, t()} | {:error, term()}
  def join(instance, room, %Identity{} = identity, can) do
    config = Config.get(instance)

    with :ok <- Policy.authorize(config.policy, identity, room, :join) do
      for topic <- [Awareness.topic(room), room_topic(room), Presence.topic(room)],
          do: :ok = Phoenix.PubSub.subscribe(config.pubsub, topic)

      if config.presence do
        meta =
          identity
          |> Identity.public()
          |> Map.merge(%{
            "joined_at" => System.system_time(:millisecond),
            "can" => to_string(can),
            "origin" => Presence.origin()
          })

        {:ok, _ref} = Presence.track(self(), Presence.topic(room), identity.key, meta)
      end

      {:ok,
       %__MODULE__{
         instance: instance,
         room: room,
         identity: identity,
         can: can,
         session_id: Awareness.session_id(self()),
         checked_at: now()
       }}
    end
  end

  @doc false
  # Ends the session while its process goes on (a LiveView whose last
  # component in the room went): as if the process had ended, for the
  # room's people, its awareness and the documents it opened.
  @spec leave(t()) :: :ok
  def leave(%__MODULE__{} = session) do
    config = Config.get(session.instance)
    Awareness.put(session.instance, session.room, session.identity.key, nil)

    if config.presence,
      do: :ok = Presence.untrack(self(), Presence.topic(session.room), session.identity.key)

    for {document_id, pid} <- session.documents do
      :ok = Phoenix.PubSub.unsubscribe(config.pubsub, Authority.topic(document_id))
      Authority.leave(pid, self())
    end

    for topic <- [
          Awareness.topic(session.room),
          room_topic(session.room),
          Presence.topic(session.room),
          Events.sessions_topic(session.room)
        ],
        do: :ok = Phoenix.PubSub.unsubscribe(config.pubsub, topic)

    :ok
  end

  @doc false
  # The room's events (Issho.Events) come to the session's process too,
  # as "event" pushes, under the policy's :read.
  @spec listen(t()) :: t()
  def listen(%__MODULE__{events: true} = session), do: session

  def listen(%__MODULE__{} = session) do
    config = Config.get(session.instance)
    :ok = Phoenix.PubSub.subscribe(config.pubsub, Events.sessions_topic(session.room))
    %{session | events: true}
  end

  @doc false
  # The people of the room now, for the session's first push.
  @spec people(t()) :: map()
  def people(%__MODULE__{instance: instance, room: room}) do
    # A room without presence (`presence: false`) knows its people by their
    # awareness only.
    if Config.get(instance).presence, do: Presence.list(Presence.topic(room)), else: %{}
  end

  @spec open(t(), String.t(), [String.t()], keyword()) :: {:ok, map(), t()} | {:error, term()}
  def open(%__MODULE__{} = session, document_id, pending \\ [], opts \\ []) do
    config = Config.get(session.instance)

    with true <- Documents.in_room?(document_id, session.room) || {:error, :other_room},
         # An inbox is its owner's, read through Issho.Inbox, in no room.
         false <- Issho.Inbox.document?(document_id) && {:error, :forbidden},
         :ok <- Policy.authorize(config.policy, session.identity, session.room, :read),
         {:ok, pid} <- Documents.open(session.instance, document_id, session.identity, opts),
         {:ok, snapshot, engine} <- join_document(config, session, document_id, pid) do
      accepted =
        Authority.accepted(pid, Enum.take(List.wrap(pending), 1_000), session.identity.key)

      session = %{
        session
        | documents: Map.put(session.documents, document_id, pid),
          places: Map.put(session.places, document_id, Issho.Binding.place(engine))
      }

      {:ok, Map.put(snapshot, "accepted", accepted), session}
    end
  end

  # The document's changes are heard before its snapshot is taken, so
  # that none falls between them: one heard twice is one the snapshot has.
  defp join_document(config, session, document_id, pid) do
    unless Map.has_key?(session.documents, document_id),
      do: :ok = Phoenix.PubSub.subscribe(config.pubsub, Authority.topic(document_id))

    Authority.join(pid, self())
  end

  @spec transact(t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def transact(%__MODULE__{} = session, document_id, transaction) do
    config = Config.get(session.instance)

    # The room's comments ask for :comment, which a reader may have.
    action = if Issho.Comments.document?(document_id), do: :comment, else: :write

    with true <- (action == :comment or session.can == :write) || {:error, :read_only},
         {:ok, pid} <- Map.fetch(session.documents, document_id) |> or_error(:not_open),
         :ok <- Policy.authorize(config.policy, session.identity, session.room, action) do
      Authority.commit(pid, transaction, session.identity)
    end
  end

  @doc false
  # Pauses, resumes or stops an agent of the room, for the session's
  # actor: the person it acts for, or anyone the policy allows :interrupt.
  @spec interrupt(t(), String.t(), :pause | :resume | :stop) :: :ok | {:error, term()}
  def interrupt(%__MODULE__{} = session, key, action) when action in [:pause, :resume, :stop] do
    if Issho.Work.allowed?(session, key) do
      config = Config.get(session.instance)
      Issho.Work.broadcast(config.pubsub, session.room, key, action, session.identity)
    else
      {:error, :forbidden}
    end
  end

  @doc false
  # Whether the room's policy lets the session do `action` now: a write
  # needs a session that writes too. For a component that keeps its data
  # outside Issho's documents (a grid of an app's database).
  @spec authorize(t(), atom()) :: :ok | {:error, term()}
  def authorize(%__MODULE__{} = session, action) when is_atom(action) do
    config = Config.get(session.instance)

    with true <- (action not in [:write, :lock] or session.can == :write) || {:error, :read_only},
         do: Policy.authorize(config.policy, session.identity, session.room, action)
  end

  @doc false
  # Sets the session's awareness state, after checking its place and locks.
  @spec aware(t(), map() | nil) :: {:ok, t()} | {:error, term()}
  def aware(%__MODULE__{} = session, nil) do
    Awareness.put(session.instance, session.room, session.identity.key, nil)
    {:ok, moved(session, nil)}
  end

  def aware(%__MODULE__{} = session, state) when is_map(state) do
    config = Config.get(session.instance)
    validator = &Map.get(session.places, &1)
    locks = Map.get(state, "locks", [])

    with true <-
           byte_size(JSON.encode!(state)) <= config.awareness_max_bytes || {:error, :too_large},
         :ok <- Place.check(state["place"], session.room, validator),
         true <- (is_list(locks) and length(locks) <= 32) || {:error, :invalid_locks},
         :ok <- check_all(locks, &Place.check(&1, session.room, validator)),
         :ok <- lock_allowed(config, session, locks) do
      Awareness.put(session.instance, session.room, session.identity.key, state)
      {:ok, moved(session, state["place"])}
    end
  end

  def aware(_session, _state), do: {:error, :invalid_state}

  # A session whose place changed: "selection.changed", for whoever waits
  # on what someone selects.
  defp moved(%__MODULE__{place: place} = session, place), do: session

  defp moved(session, place) do
    Events.broadcast(Config.get(session.instance).pubsub, %Event{
      name: "selection.changed",
      room: session.room,
      document: place && place["doc"],
      by: session.identity,
      data: %{place: place, session: session.session_id},
      at: DateTime.utc_now()
    })

    %{session | place: place}
  end

  defp lock_allowed(_config, _session, []), do: :ok

  defp lock_allowed(config, session, _locks) do
    if session.can == :write,
      do: Policy.authorize(config.policy, session.identity, session.room, :lock),
      else: {:error, :read_only}
  end

  defp check_all(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc false
  # What to do with a message the session's process received: `{:push,
  # event, payload, session}`, `{:skip, session}` or `{:stop, reason}`.
  @spec handle(t(), term()) ::
          {:push, String.t(), map(), t()} | {:skip, t()} | {:stop, term()}
  def handle(%__MODULE__{} = session, {Issho, :transaction, document_id, event}) do
    config = Config.get(session.instance)

    case Policy.authorize(config.policy, session.identity, session.room, :read) do
      :ok -> {:push, "tx", %{"doc" => document_id, "event" => event}, session}
      {:error, _} -> {:stop, :unauthorized}
    end
  end

  def handle(%__MODULE__{} = session, {Issho, :awareness, _room, frame}) do
    with {:ok, session} <- recheck(session) do
      frame = %{frame | "states" => Map.delete(frame["states"], session.session_id)}

      # A full frame always goes: even empty, it says which sessions the
      # node no longer has.
      if frame["states"] == %{} and frame["gone"] == [] and not frame["full"],
        do: {:skip, session},
        else: {:push, "aware", frame, session}
    end
  end

  def handle(%__MODULE__{room: room} = session, {Issho, :room_event, %Event{room: room} = event}) do
    config = Config.get(session.instance)

    case Policy.authorize(config.policy, session.identity, session.room, :read) do
      :ok -> {:push, "event", event, session}
      {:error, _} -> {:stop, :unauthorized}
    end
  end

  def handle(%__MODULE__{identity: %{key: key}, room: room}, {Issho, :revoke, room, key}),
    do: {:stop, :revoked}

  def handle(
        %__MODULE__{identity: %{key: key}, room: room} = session,
        {Issho, :interrupt, room, key, action, by}
      ),
      do: {:push, "interrupt", %{"action" => action, "by" => by}, session}

  def handle(session, %Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}),
    do: {:push, "presence_diff", diff, session}

  def handle(session, _message), do: {:skip, session}

  defp recheck(session) do
    if now() - session.checked_at < @recheck_ms do
      {:ok, session}
    else
      config = Config.get(session.instance)

      case Policy.authorize(config.policy, session.identity, session.room, :join) do
        :ok -> {:ok, %{session | checked_at: now()}}
        {:error, _} -> {:stop, :unauthorized}
      end
    end
  end

  @doc false
  @spec room_topic(String.t()) :: String.t()
  def room_topic(room), do: "issho:room:" <> room

  defp or_error({:ok, value}, _reason), do: {:ok, value}
  defp or_error(:error, reason), do: {:error, reason}

  defp now, do: System.monotonic_time(:millisecond)
end
