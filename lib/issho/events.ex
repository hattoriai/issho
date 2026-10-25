defmodule Issho.Events do
  @moduledoc """
  A room's events (`Issho.Event`), on every node: subscribe to act on what
  happens in it (an admin page, a job, an agent waiting for someone), and
  emit an app's or a component's own.

      Issho.Events.subscribe(MyApp.Issho, "board:42")

      def handle_info({Issho, :event, %Issho.Event{name: "document.changed"} = event}, socket) do
        ...
      end

      Issho.Events.emit(MyApp.Issho, "board:42", "retro.voted", by: current_user, data: %{card: id})

  Each event is also a `:telemetry` event, once in the cluster, for an
  app's own handlers (a notification, a log, a metric):

    * `[:issho, :event]`, with the measurement `:system_time`, and the
      metadata `:event` (the `Issho.Event`) and `:pubsub`.

  A LiveView's components receive the events they ask for
  (`Issho.Live.subscribe/3`), and so do participants that join with
  `events: true` (`Issho.join_as/4`), such as the agents of
  `Issho.Agents`, which wait for them (the `wait_for_events` tool).
  """

  alias Issho.{Config, Event, Identity}

  @doc "Subscribes the calling process to a room's events: `{Issho, :event, %Issho.Event{}}`."
  @spec subscribe(atom(), String.t()) :: :ok | {:error, term()}
  def subscribe(instance, room) when is_atom(instance) and is_binary(room),
    do: Phoenix.PubSub.subscribe(Config.get(instance).pubsub, topic(room))

  @doc "Stops the calling process's subscription to a room's events."
  @spec unsubscribe(atom(), String.t()) :: :ok
  def unsubscribe(instance, room) when is_atom(instance) and is_binary(room),
    do: Phoenix.PubSub.unsubscribe(Config.get(instance).pubsub, topic(room))

  @doc """
  Emits an event in a room. Options: `:document`, `:by` (an actor, as
  `Issho.Actor` says them, or an `Issho.Identity`) and `:data` (a map).
  An event whose data has `mentions` (keys) lands in the inbox of each
  (`Issho.Inbox`), as a comment's does.
  """
  @spec emit(atom(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def emit(instance, room, name, opts \\ [])
      when is_atom(instance) and is_binary(room) and is_binary(name) do
    by =
      case Keyword.get(opts, :by) do
        nil -> nil
        actor -> Identity.new(actor)
      end

    event = %Event{
      name: name,
      room: room,
      document: Keyword.get(opts, :document),
      by: by,
      data: Map.new(Keyword.get(opts, :data, %{})),
      at: DateTime.utc_now()
    }

    config = Config.get(instance)

    with :ok <- broadcast(config.pubsub, event),
         do: Issho.Inbox.deliver(config, event)
  end

  @doc """
  Whether an event's name is one of `names`: a name, a name ending in
  `".*"` for all of a kind (`"comment.*"`), or `:all`.

      iex> Issho.Events.match?(["comment.*"], "comment.created")
      true
      iex> Issho.Events.match?(["document.changed"], "person.joined")
      false
  """
  @spec match?(:all | [String.t()], String.t()) :: boolean()
  def match?(:all, _name), do: true

  def match?(names, name) when is_list(names) and is_binary(name) do
    Enum.any?(names, fn
      ^name ->
        true

      wanted ->
        String.ends_with?(wanted, ".*") and
          String.starts_with?(name, String.trim_trailing(wanted, "*"))
    end)
  end

  @doc false
  @spec broadcast(atom(), Event.t()) :: :ok | {:error, term()}
  def broadcast(pubsub, %Event{room: room} = event) do
    :telemetry.execute(
      [:issho, :event],
      %{system_time: System.system_time()},
      %{event: event, pubsub: pubsub}
    )

    # The sessions of the room hear it on a topic of their own, so that a
    # process with a session that also subscribed itself gets both. A
    # private event (`to`) goes to the sessions only, each its own.
    with :ok <- public(pubsub, event),
         do: Phoenix.PubSub.broadcast(pubsub, sessions_topic(room), {Issho, :room_event, event})
  end

  defp public(_pubsub, %Event{to: to}) when is_list(to), do: :ok

  defp public(pubsub, event),
    do: Phoenix.PubSub.broadcast(pubsub, topic(event.room), {Issho, :event, event})

  @doc false
  # Whether a private event is for this identity: its key, or the person
  # it acts for.
  @spec for?(Event.t(), Issho.Identity.t()) :: boolean()
  def for?(%Event{to: nil}, _identity), do: true

  def for?(%Event{to: to}, identity),
    do: identity.key in to or (identity.on_behalf_of != nil and identity.on_behalf_of.key in to)

  defp topic(room), do: "issho:events:" <> room

  @doc false
  @spec sessions_topic(String.t()) :: String.t()
  def sessions_topic(room), do: "issho:session_events:" <> room
end
