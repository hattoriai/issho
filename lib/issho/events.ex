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

    broadcast(Config.get(instance).pubsub, event)
  end

  @doc false
  @spec broadcast(atom(), Event.t()) :: :ok | {:error, term()}
  def broadcast(pubsub, %Event{room: room} = event),
    do: Phoenix.PubSub.broadcast(pubsub, topic(room), {Issho, :event, event})

  defp topic(room), do: "issho:events:" <> room
end
