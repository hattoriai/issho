defmodule Issho.Requests do
  @moduledoc ~S"""
  A person asks their agent, privately, about what they selected, and
  the agent answers in place: a suggestion they take or leave.

      {:ok, request} = Issho.Live.ask(room, "Make this shorter", agent: "agent:42")

  ## The request

  It goes to the agent named, and to no one else: not a room event, not
  in the room's comments. Its words, the person's place (and its label,
  `Issho.Place`), the version of the document they saw (`Issho.Version`)
  and the app's own data (`%{"block" => …}`) are bounded and cleaned
  (`Issho.Text`), and are data for the agent, never instructions to it.

  The policy says who may ask whom (`c:Issho.Policy.ask/3`): a policy
  without it lets no one ask. The person must read the room, and so must
  the agent when it reads its requests.

  The agent hears it however it is:

    * in the room, as an `"agent.asked"` event (`wait_for_events`), its
      own and no one else's;
    * away, in its inbox (`Issho.Inbox`, the `inbox` tool), which wakes
      it (`:on_mention`, and the MCP clients' nudge). An item heard in the
      room is read there too.

  ## The answer

  The agent writes a stream (`Issho.Streams`, the `start_stream` tool)
  for the person, at the place, with the request's id (`request:`): a
  suggestion, which the app shows as it comes. Such a stream's events
  (`"stream.started"`, …, `"stream.closed"`) carry the request's id, and
  go only to the person, their agents and its writer: what was asked,
  answered and decided stays theirs.

  ## Taken or left

  What taking it does is the app's: `accept/4` runs the app's change (a
  function, made `if_revision` the version the request saw, so a
  selection changed since is refused as stale, `Issho.Transaction`), and
  closes the stream `"accepted"` only when the change is made. Refused,
  the suggestion stays to look at, and the refusal says why. Two people
  (or two tabs) taking it at once make the change once: the second finds
  it closed. `reject/3` closes it `"rejected"`, with no change. The agent
  hears the outcome (`"stream.closed"`).

  An agent's stream says which request it answers; the app's request
  says to whom it went. `accept/4` checks they agree, and that the stream
  is the person's.
  """

  alias Issho.{Config, Event, Events, Identity, Place, Policy, Stream, Streams, Text}

  @max_text 4_000
  @max_data_bytes 4_096

  @typedoc "A request: its id, who asked whom, in which room, what, where, and on what version."
  @type t :: %{
          required(:id) => String.t(),
          required(:room) => String.t(),
          required(:by) => Identity.t(),
          required(:to) => String.t(),
          required(:text) => String.t(),
          required(:place) => map() | nil,
          required(:version) => String.t() | nil,
          required(:data) => map()
        }

  @typedoc "The app's change, on taking an answer: `{:ok, receipt}` or `{:error, reason}`."
  @type change :: (t() -> {:ok, term()} | {:error, term()})

  @doc """
  Asks the agent with the key `:agent` privately, in the room, as the
  person `by` (an actor or an identity). Options: `:agent` (required),
  `:place` (where; the person's place unless the caller says), `:version`
  (the version of the place's document they saw), `:data` (the app's,
  a small JSON map). Gives `{:ok, request}`, to keep: its id comes back
  on the answer's stream.
  """
  @spec ask(atom(), String.t(), Issho.Actor.t() | Identity.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def ask(instance, room, by, text, opts) when is_binary(room) and is_binary(text) do
    config = Config.get(instance)
    identity = Identity.new(by)
    agent = Keyword.get(opts, :agent)
    place = Place.clean(opts[:place])

    with true <- is_binary(agent) || {:error, :no_agent},
         :ok <- Policy.authorize(config.policy, identity, room, :read),
         :ok <- Policy.ask(config.policy, identity, room, agent),
         {:ok, text} <- words(text),
         :ok <- Place.check(place, room, fn _doc -> nil end),
         {:ok, version} <- version(opts[:version]),
         {:ok, data} <- data(Keyword.get(opts, :data, %{})) do
      request = %{
        id: Issho.Transaction.id(),
        room: room,
        by: identity,
        to: agent,
        text: text,
        place: place,
        version: version,
        data: data
      }

      deliver(config, request)
      {:ok, request}
    end
  end

  @doc """
  Takes the answer: runs `change` (the app's, a function of the request
  that gives `{:ok, receipt}` or `{:error, reason}`, made with
  `if_revision: request.version`) and, made, closes the stream
  `"accepted"`. Gives the change's result; `{:error, :closed}` for an
  answer already taken or left. `who` takes it: the person who asked,
  who must still read and write in the room (not the agent that wrote
  the answer).
  """
  @spec accept(atom(), t(), String.t(), Issho.Actor.t() | Identity.t(), change()) ::
          {:ok, term()} | {:error, term()}
  def accept(instance, request, stream_id, who, change) when is_function(change, 1) do
    identity = Identity.new(who)

    # One at a time for a stream, in the cluster: a second finds it closed.
    :global.trans({{__MODULE__, instance, stream_id}, self()}, fn ->
      with {:ok, stream} <- answer(instance, request, stream_id, identity),
           :ok <- Policy.authorize(Config.get(instance).policy, identity, request.room, :write),
           {:ok, receipt} <- change.(request) do
        _ = Streams.close(stream, "accepted")
        {:ok, receipt}
      end
    end)
  end

  @doc "Leaves the answer (its asker does): closes its stream `\"rejected\"`, with no change."
  @spec reject(atom(), t(), String.t(), Issho.Actor.t() | Identity.t()) :: :ok | {:error, term()}
  def reject(instance, request, stream_id, who) do
    :global.trans({{__MODULE__, instance, stream_id}, self()}, fn ->
      with {:ok, stream} <- answer(instance, request, stream_id, Identity.new(who)),
           do: Streams.close(stream, "rejected")
    end)
  end

  # The stream answering the request, for the person, from the agent
  # asked, not closed yet; taken or left by the person who asked, who may
  # still read the room.
  defp answer(instance, request, stream_id, identity) do
    case Streams.get(instance, stream_id) do
      {:ok, %Stream{state: state} = stream} when state != :closed ->
        cond do
          not answers?(stream, request) -> {:error, :not_the_answer}
          identity.key != request.by.key -> {:error, :forbidden}
          not Streams.visible?(stream, identity) -> {:error, :forbidden}
          true -> {:ok, stream}
        end

      _closed_or_gone ->
        {:error, :closed}
    end
  end

  # Its request's, by the agent asked, for the person who asked.
  defp answers?(stream, request) do
    Stream.request(stream) == request.id and stream.by != nil and stream.by.key == request.to and
      stream.for == request.by.key
  end

  # To the agent's queue if it is in the room, and to its inbox: it reads
  # it either way, once.
  defp deliver(config, request) do
    event = %Event{
      name: "agent.asked",
      room: request.room,
      document: request.place && request.place["doc"],
      by: request.by,
      to: [request.to],
      data: %{
        request: request.id,
        text: request.text,
        place: request.place,
        version: request.version,
        data: request.data
      },
      at: DateTime.utc_now()
    }

    :ok = Events.broadcast(config.pubsub, event)
    Issho.Inbox.deliver_to(config, request.to, event)
  end

  defp words(text) do
    case Text.clean(text, max: @max_text) |> String.trim() do
      "" -> {:error, :empty_request}
      words -> {:ok, words}
    end
  end

  defp version(nil), do: {:ok, nil}

  defp version(token) do
    with {:ok, _} <- Issho.Version.parse(token), do: {:ok, token}
  end

  defp data(data) when is_map(data) do
    if byte_size(JSON.encode!(data)) <= @max_data_bytes,
      do: {:ok, Text.for_model(data)},
      else: {:error, :too_large}
  rescue
    _ -> {:error, :invalid_data}
  end

  defp data(_data), do: {:error, :invalid_data}
end
