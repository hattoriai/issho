defmodule Issho.Streams do
  @moduledoc ~S"""
  Streams of a room: output that a process writes a piece at a time (a
  model's answer, an agent's report, an import's log), that people see as
  it comes, and find again when they come back: from another page,
  another tab, after their connection dropped, on another node.

      {:ok, stream} =
        Issho.Streams.start(MyApp.Issho, "notebook:7",
          kind: "summary",
          for: ada,
          place: %{"doc" => "notebook:7/intro", "at" => %{"node" => block_id}},
          by: claude
        )

      :ok = Issho.Streams.append(stream, "## Summary\n\n")
      :ok = Issho.Streams.append(stream, "The plan holds…")
      :ok = Issho.Streams.finish(stream)

  Issho keeps a stream's chunks and sends them on; it does not read them.
  What a stream is, each component or app decides: a suggestion in a
  text, a card waiting on a canvas, a chat's answer, a log.

  ## Who sees it

  `:for` is required: a person (an actor, or a key), who sees it, and so
  do their agents (`on_behalf_of`); `:room`, everyone the policy lets
  read the room; or `:policy`, whomever the policy allows the action
  `:read_stream` in the room. Its writer (`:by`) sees it too. Every reader
  may read the room (`:read`).

  ## Seen as it comes, found again

  `subscribe/4` gives the stream as it is now, its content so far, and
  from then on sends the subscriber what comes, in order, with nothing
  missed or sent twice:

    * `{Issho, :stream, id, {:chunk, data}}`
    * `{Issho, :stream, id, :finished}`
    * `{Issho, :stream, id, {:failed, reason}}`
    * `{Issho, :stream, id, {:closed, outcome}}`
    * `{Issho, :stream, id, :gone}`: kept no longer.

  `watch/3` subscribes to every stream of a room the caller may see, and
  to the news of new ones: `{Issho, :stream_started, room, stream}`, on
  which the watcher calls `subscribe/4` (it is refused a stream it may not
  see). A LiveView does it with `Issho.Live.streams/1`, which does both.

  ## Its life

  A stream lives while it is written. Finished (`finish/1`) or failed
  (`fail/2`), it is kept for `:keep` milliseconds (the instance's
  `:stream_keep`, five minutes), for those who come back, then goes.
  `close/2` ends it at once, with an outcome the app names (`"accepted"`,
  `"rejected"`, `"stopped"`, its own): a suggestion taken or turned down.

  Its writer is the process that starts it (or `:writer`): when it exits
  while the stream is written, the stream fails (`"writer_exited"`), or
  finishes with `on_exit: :finish`. No stream is left being written.

  Each start, finish, failure and close is an event of the room
  (`Issho.Event`): `"stream.started"`, `"stream.finished"`,
  `"stream.failed"` and `"stream.closed"`, with `data` `%{stream: id,
  kind: kind, for: for}` and the `reason` or `outcome`; so an agent learns
  whether its draft was taken. Their content is not in them. A stream
  answering a request (`meta: %{request: id}`, `Issho.Requests`) says
  which in its events, which go to its person, their agents and its
  writer only.

  ## Limits

  A stream holds at most the instance's `:stream_max_bytes` (1 MB): one
  that would hold more fails (`"too_large"`). A room has at most
  `:room_max_streams` (32) at once. Streams are in memory, as presence
  is: a stream does not outlive its node.

  Each stream is a process (`:gen_statem`), named in the whole cluster
  (`:global`), so it is found from any node; the streams of a room are a
  process group (`:pg`).
  """

  @behaviour :gen_statem

  alias Issho.{Config, Event, Events, Identity, Policy, Stream}

  @type ref :: Stream.t() | {atom(), String.t()}

  ## API

  @doc """
  Starts a stream in a room, written by the caller (or `:writer`).
  Options: `:for` (required), `:kind`, `:place`, `:meta`, `:by` (an actor
  or an identity: who writes it, as the room sees them), `:writer`,
  `:keep` (milliseconds), `:on_exit` (`:fail` or `:finish`).
  """
  @spec start(atom(), String.t(), keyword()) :: {:ok, Stream.t()} | {:error, term()}
  def start(instance, room, opts) when is_atom(instance) and is_binary(room) do
    config = Config.get(instance)
    opts = Keyword.replace_lazy(opts, :place, &Issho.Place.clean/1)

    with {:ok, for} <- for_of(Keyword.fetch(opts, :for)),
         :ok <- Issho.Place.check(opts[:place], room, fn _doc -> nil end),
         true <-
           room_count(instance, room) < config.room_max_streams || {:error, :too_many_streams} do
      id = Issho.Transaction.id()

      stream = %Stream{
        id: id,
        instance: instance,
        room: room,
        kind: opts[:kind] && to_string(opts[:kind]),
        for: for,
        by: opts[:by] && Identity.new(opts[:by]),
        place: opts[:place],
        meta: Map.new(Keyword.get(opts, :meta, %{})),
        started_at: DateTime.utc_now(),
        pid: nil
      }

      settings = %{
        writer: Keyword.get(opts, :writer, self()),
        keep: Keyword.get(opts, :keep, config.stream_keep),
        on_exit: Keyword.get(opts, :on_exit, :fail)
      }

      spec = %{
        id: __MODULE__,
        start:
          {:gen_statem, :start_link,
           [{:global, name(instance, id)}, __MODULE__, {stream, settings}, []]},
        restart: :temporary
      }

      case DynamicSupervisor.start_child(Config.child_name(instance, Streams), spec) do
        {:ok, pid} -> {:ok, %{stream | pid: pid}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp for_of({:ok, scope}) when scope in [:room, :policy], do: {:ok, scope}
  defp for_of({:ok, key}) when is_binary(key), do: {:ok, key}
  defp for_of({:ok, actor}) when not is_nil(actor), do: {:ok, Identity.new(actor).key}
  defp for_of(_missing), do: {:error, :no_reader}

  @doc """
  Adds a chunk (a binary) to the stream. `{:error, :not_writing}` once it
  is done; `{:error, :too_large}` when the stream would hold more than its
  limit, and it fails.
  """
  @spec append(ref(), iodata()) :: :ok | {:error, term()}
  def append(stream, data), do: call(stream, {:append, IO.iodata_to_binary(data)})

  @doc "Finishes the stream: it is complete, and kept for those who come back."
  @spec finish(ref()) :: :ok | {:error, term()}
  def finish(stream), do: call(stream, :finish)

  @doc "Fails the stream, with a reason (a string or an atom)."
  @spec fail(ref(), String.t() | atom()) :: :ok | {:error, term()}
  def fail(stream, reason), do: call(stream, {:fail, to_string(reason)})

  @doc """
  Closes the stream now, with an outcome the app names (`:accepted`,
  `:rejected`, `:stopped`, its own): it goes, and its subscribers hear
  how. From a person's page, `Issho.Live.close_stream/3` checks they may
  see it first.
  """
  @spec close(ref(), String.t() | atom()) :: :ok | {:error, term()}
  def close(stream, outcome), do: call(stream, {:close, to_string(outcome)})

  @doc "The stream as it is now: `{:ok, stream}` or `{:error, :not_found}`."
  @spec get(atom(), String.t()) :: {:ok, Stream.t()} | {:error, :not_found}
  def get(instance, id), do: call({instance, id}, :get)

  @doc """
  The streams of a room that `who` (an actor or an identity) may see, as
  they are now, oldest first.
  """
  @spec list(atom(), String.t(), Issho.Actor.t() | Identity.t()) :: [Stream.t()]
  def list(instance, room, who) do
    identity = Identity.new(who)

    instance
    |> members(room)
    |> Enum.flat_map(fn pid ->
      case call(pid, :get) do
        {:ok, stream} -> [stream]
        {:error, _gone} -> []
      end
    end)
    |> Enum.filter(&visible?(&1, identity))
    |> Enum.sort_by(& &1.started_at, DateTime)
  end

  @doc """
  Subscribes `pid` (the caller) to a stream that `who` may see: gives the
  stream as it is now, then sends what comes (see above).
  `{:error, :forbidden}` for one they may not see.
  """
  @spec subscribe(atom(), String.t() | Stream.t(), Issho.Actor.t() | Identity.t(), pid()) ::
          {:ok, Stream.t()} | {:error, :forbidden | :not_found}
  def subscribe(instance, stream_or_id, who, pid \\ self())

  def subscribe(instance, %Stream{id: id}, who, pid), do: subscribe(instance, id, who, pid)

  def subscribe(instance, id, who, pid) when is_binary(id) do
    identity = Identity.new(who)

    with {:ok, stream} <- get(instance, id),
         true <- visible?(stream, identity) || {:error, :forbidden},
         do: call({instance, id}, {:subscribe, pid})
  end

  @doc "Stops sending a stream to `pid` (the caller)."
  @spec unsubscribe(ref(), pid()) :: :ok
  def unsubscribe(stream, pid \\ self()) do
    case call(stream, {:unsubscribe, pid}) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  Subscribes the caller to every stream of the room that `who` may see,
  and to the news of new ones (`{Issho, :stream_started, room, stream}`).
  Gives the streams, as they are now.
  """
  @spec watch(atom(), String.t(), Issho.Actor.t() | Identity.t()) :: {:ok, [Stream.t()]}
  def watch(instance, room, who) do
    identity = Identity.new(who)
    :ok = Phoenix.PubSub.subscribe(Config.get(instance).pubsub, topic(room))

    streams =
      for stream <- list(instance, room, identity),
          {:ok, stream} <- [subscribe(instance, stream.id, identity)],
          do: stream

    {:ok, streams}
  end

  @doc "Stops the news of a room's new streams (`watch/3`)."
  @spec unwatch(atom(), String.t()) :: :ok
  def unwatch(instance, room),
    do: Phoenix.PubSub.unsubscribe(Config.get(instance).pubsub, topic(room))

  @doc """
  Whether `who` (an identity) may see the stream: they may read its room,
  and it is for them (or for whom they act), for the room, for whom the
  policy allows `:read_stream`, or they write it.
  """
  @spec visible?(Stream.t(), Identity.t()) :: boolean()
  def visible?(%Stream{} = stream, %Identity{} = identity) do
    policy = Config.get(stream.instance).policy

    Policy.authorize(policy, identity, stream.room, :read) == :ok and
      (writer?(stream, identity) or
         case stream.for do
           :room -> true
           :policy -> Policy.authorize(policy, identity, stream.room, :read_stream) == :ok
           key -> key in [identity.key, identity.on_behalf_of && identity.on_behalf_of.key]
         end)
  end

  defp writer?(%Stream{by: %Identity{key: key}}, %Identity{key: key}), do: true
  defp writer?(_stream, _identity), do: false

  defp name(instance, id), do: {__MODULE__, instance, id}

  defp topic(room), do: "issho:streams:" <> room

  defp members(instance, room),
    do: :pg.get_members(Config.child_name(instance, StreamGroups), room)

  defp room_count(instance, room), do: length(members(instance, room))

  # A call to the stream's process, or `{:error, :not_found}` when it is
  # gone (or going).
  defp call(%Stream{pid: pid}, message) when is_pid(pid), do: call(pid, message)

  defp call({instance, id}, message) do
    case :global.whereis_name(name(instance, id)) do
      pid when is_pid(pid) -> call(pid, message)
      :undefined -> {:error, :not_found}
    end
  end

  defp call(pid, message) when is_pid(pid) do
    :gen_statem.call(pid, message, 5_000)
  catch
    :exit, _reason -> {:error, :not_found}
  end

  ## Server: a state machine of `:writing`, `:finished` and `:failed`.
  ## Done, it is kept for its time (a state timeout), then goes; closed,
  ## it goes at once. Its data is the stream, its chunks (newest first),
  ## its subscribers (monitored) and its writer (monitored).

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init({stream, settings}) do
    stream = %{stream | pid: self()}
    :ok = :pg.join(Config.child_name(stream.instance, StreamGroups), stream.room, self())
    Process.monitor(settings.writer)

    data = %{
      stream: stream,
      chunks: [],
      subscribers: %{},
      writer: settings.writer,
      keep: settings.keep,
      on_exit: settings.on_exit,
      max: Config.get(stream.instance).stream_max_bytes
    }

    config = Config.get(stream.instance)

    Phoenix.PubSub.broadcast(
      config.pubsub,
      topic(stream.room),
      {Issho, :stream_started, stream.room, stream}
    )

    emit(data, "stream.started", %{place: stream.place})
    {:ok, :writing, data}
  end

  @impl true
  def handle_event(:enter, same, same, _data), do: :keep_state_and_data

  def handle_event(:enter, _writing, done, data) when done in [:finished, :failed],
    do: {:keep_state_and_data, {:state_timeout, data.keep, :expired}}

  def handle_event(:state_timeout, :expired, _done, data) do
    tell(data, :gone)
    {:stop, :normal}
  end

  def handle_event({:call, from}, {:append, chunk}, :writing, data) do
    size = data.stream.size + byte_size(chunk)

    if size > data.max do
      {:next_state, :failed, failed(data, "too_large"), {:reply, from, {:error, :too_large}}}
    else
      tell(data, {:chunk, chunk})
      stream = %{data.stream | size: size}
      {:keep_state, %{data | stream: stream, chunks: [chunk | data.chunks]}, {:reply, from, :ok}}
    end
  end

  def handle_event({:call, from}, :finish, :writing, data),
    do: {:next_state, :finished, finished(data), {:reply, from, :ok}}

  def handle_event({:call, from}, {:fail, reason}, :writing, data),
    do: {:next_state, :failed, failed(data, reason), {:reply, from, :ok}}

  def handle_event({:call, from}, {action, _arg}, _done, _data) when action in [:append, :fail],
    do: {:keep_state_and_data, {:reply, from, {:error, :not_writing}}}

  def handle_event({:call, from}, :finish, _done, _data),
    do: {:keep_state_and_data, {:reply, from, {:error, :not_writing}}}

  def handle_event({:call, from}, {:close, outcome}, state, data) do
    stream = %{data.stream | state: :closed, outcome: outcome}
    data = %{data | stream: stream}
    tell(data, {:closed, outcome})
    emit(data, "stream.closed", %{outcome: outcome, was: Atom.to_string(state)})
    {:stop_and_reply, :normal, {:reply, from, :ok}}
  end

  def handle_event({:call, from}, :get, state, data),
    do: {:keep_state_and_data, {:reply, from, {:ok, now(data, state)}}}

  def handle_event({:call, from}, {:subscribe, pid}, state, data) do
    subscribers =
      if Map.has_key?(data.subscribers, pid),
        do: data.subscribers,
        else: Map.put(data.subscribers, pid, Process.monitor(pid))

    {:keep_state, %{data | subscribers: subscribers}, {:reply, from, {:ok, now(data, state)}}}
  end

  def handle_event({:call, from}, {:unsubscribe, pid}, _state, data) do
    {ref, subscribers} = Map.pop(data.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:keep_state, %{data | subscribers: subscribers}, {:reply, from, :ok}}
  end

  # Its writer went while it wrote.
  def handle_event(
        :info,
        {:DOWN, _ref, :process, writer, _reason},
        :writing,
        %{writer: writer} = data
      ) do
    case data.on_exit do
      :finish -> {:next_state, :finished, finished(data)}
      :fail -> {:next_state, :failed, failed(data, "writer_exited")}
    end
  end

  def handle_event(:info, {:DOWN, _ref, :process, pid, _reason}, _state, data),
    do: {:keep_state, %{data | subscribers: Map.delete(data.subscribers, pid)}}

  def handle_event(:info, _message, _state, _data), do: :keep_state_and_data

  defp finished(data) do
    data = put_in(data.stream.state, :finished)
    tell(data, :finished)
    emit(data, "stream.finished", %{size: data.stream.size})
    data
  end

  defp failed(data, reason) do
    data = %{data | stream: %{data.stream | state: :failed, outcome: reason}}
    tell(data, {:failed, reason})
    emit(data, "stream.failed", %{reason: reason})
    data
  end

  # The stream as it is now, with what was written so far.
  defp now(data, state) do
    %{data.stream | state: state, content: data.chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp tell(data, message) do
    for pid <- Map.keys(data.subscribers),
        do: send(pid, {Issho, :stream, data.stream.id, message})
  end

  # A stream answering a request (Issho.Requests) says which, to its
  # person, their agents and its writer only.
  defp emit(%{stream: stream}, name, data) do
    {to, data} =
      case Stream.request(stream) do
        nil -> {nil, data}
        request -> {audience(stream), Map.put(data, :request, request)}
      end

    Events.broadcast(Config.get(stream.instance).pubsub, %Event{
      name: name,
      room: stream.room,
      by: stream.by,
      to: to,
      data: Map.merge(%{stream: stream.id, kind: stream.kind, for: for_word(stream.for)}, data),
      at: DateTime.utc_now()
    })
  end

  defp audience(%Stream{for: for, by: by}) when is_binary(for),
    do: Enum.uniq([for | if(by, do: [by.key], else: [])])

  defp audience(_stream), do: nil

  defp for_word(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp for_word(key), do: key
end
