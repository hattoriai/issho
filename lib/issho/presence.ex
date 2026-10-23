defmodule Issho.Presence do
  @moduledoc """
  Who is in a room: `Phoenix.Presence`, as it is, on your app's PubSub.

  Issho starts it for you (the instance's `:presence` option, `true`
  unless given) and tracks each session under its actor's key, so an actor
  in two tabs is one entry with two metas. Each meta is the actor's public
  identity (`Issho.Identity.public/1`) and when it joined.

  Presence is for who is here, which changes when people come and go.
  Where they are changes many times a second and goes through awareness
  (`Issho.Awareness`), which is not replicated by Presence's CRDT.

  It emits the room's `"person.joined"` when an actor's first session comes,
  and `"person.left"` when its last one goes (`Issho.Events`), once in the
  cluster: from the node of that session.

  An app with several Issho instances on one node gives each a
  `presence: false` but the first, and they share this one (and its
  PubSub, for those events).
  """

  use Phoenix.Presence, otp_app: :issho

  alias Issho.{Event, Events, Identity}

  @prefix "issho:presence:"

  @doc false
  @spec topic(String.t()) :: String.t()
  def topic(room), do: @prefix <> room

  @doc "The actors in a room: their keys and public identities."
  @spec people(String.t()) :: %{String.t() => map()}
  def people(room) do
    for {key, %{metas: [meta | _]}} <- list(topic(room)), into: %{}, do: {key, meta}
  end

  @doc false
  # Where this node's sessions say they are from, in their metas: so that
  # of the nodes that all see a session come and go, only its own emits.
  @spec origin() :: String.t()
  def origin do
    case :persistent_term.get({__MODULE__, :origin}, nil) do
      nil ->
        origin = Base.url_encode64(:crypto.strong_rand_bytes(9))
        :persistent_term.put({__MODULE__, :origin}, origin)
        origin

      origin ->
        origin
    end
  end

  @doc false
  # The PubSub of the room's events, the instance's that started this presence.
  @spec put_pubsub(atom()) :: :ok
  def put_pubsub(pubsub), do: :persistent_term.put({__MODULE__, :pubsub}, pubsub)

  @impl true
  def init(_opts), do: {:ok, %{}}

  # Runs on every node for every change of a room's people: an actor's
  # first session to come, or its last to go, is an event once, on the
  # node of that session.
  @impl true
  def handle_metas(@prefix <> room, %{joins: joins, leaves: leaves}, presences, state) do
    pubsub = :persistent_term.get({__MODULE__, :pubsub}, nil)
    here = origin()

    if pubsub do
      for {key, %{metas: metas}} <- joins,
          not Map.has_key?(leaves, key),
          length(Map.get(presences, key, [])) == length(metas),
          meta = Enum.find(metas, &(&1["origin"] == here)),
          do: emit(pubsub, "person.joined", room, meta)

      for {key, %{metas: metas}} <- leaves,
          not Map.has_key?(presences, key),
          meta = Enum.find(metas, &(&1["origin"] == here)),
          do: emit(pubsub, "person.left", room, meta)
    end

    {:ok, state}
  end

  def handle_metas(_topic, _diff, _presences, state), do: {:ok, state}

  defp emit(pubsub, name, room, meta) do
    Events.broadcast(pubsub, %Event{
      name: name,
      room: room,
      by: Identity.from_claims(meta),
      data: %{can: meta["can"]},
      at: DateTime.utc_now()
    })
  end
end
