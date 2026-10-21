defmodule Issho.Session do
  @moduledoc false
  # One actor's presence in one room, the same for a browser's channel
  # (Issho.Channel) and an agent's process (Issho.Participant): joining,
  # opening the room's documents, transactions, awareness, and the checks
  # in both directions. The functions run in the session's own process.

  alias Issho.{Authority, Awareness, Config, Documents, Identity, Place, Policy, Presence}

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
            "can" => to_string(can)
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
  # The people of the room now, for the session's first push.
  @spec people(t()) :: map()
  def people(%__MODULE__{room: room}), do: Presence.list(Presence.topic(room))

  @spec open(t(), String.t(), [String.t()], keyword()) :: {:ok, map(), t()} | {:error, term()}
  def open(%__MODULE__{} = session, document_id, pending \\ [], opts \\ []) do
    config = Config.get(session.instance)

    with true <- Documents.in_room?(document_id, session.room) || {:error, :other_room},
         :ok <- Policy.authorize(config.policy, session.identity, session.room, :read),
         {:ok, pid} <- Documents.open(session.instance, document_id, session.identity, opts),
         {:ok, snapshot, engine} <- Authority.join(pid, self()) do
      unless Map.has_key?(session.documents, document_id),
        do: :ok = Phoenix.PubSub.subscribe(config.pubsub, Authority.topic(document_id))

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

  @spec transact(t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def transact(%__MODULE__{} = session, document_id, transaction) do
    config = Config.get(session.instance)

    with true <- session.can == :write || {:error, :read_only},
         {:ok, pid} <- Map.fetch(session.documents, document_id) |> or_error(:not_open),
         :ok <- Policy.authorize(config.policy, session.identity, session.room, :write) do
      Authority.commit(pid, transaction, session.identity.key)
    end
  end

  @doc false
  # Sets the session's awareness state, after checking its place and locks.
  @spec aware(t(), map() | nil) :: {:ok, t()} | {:error, term()}
  def aware(%__MODULE__{} = session, nil) do
    Awareness.put(session.instance, session.room, session.identity.key, nil)
    {:ok, session}
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
      {:ok, session}
    end
  end

  def aware(_session, _state), do: {:error, :invalid_state}

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

  def handle(%__MODULE__{identity: %{key: key}, room: room}, {Issho, :revoke, room, key}),
    do: {:stop, :revoked}

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
