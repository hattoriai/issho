# Streams

Much of what happens in a room is long and written a piece at a time: a
model's answer, an agent's report, a summary of a board, an import's log.
A stream of a room (`Issho.Streams`) is that output. Any process of your
app writes it; the pages and agents allowed to see it get it as it comes;
and Issho keeps it while it is written and for a while after, so that a
person who goes to another page, opens another tab, or loses their
connection finds it again where it got to, not where they left it.

Issho keeps the chunks and sends them on. It does not read them: what a
stream is, a component or your app decides. Kotoba can show one as a
suggestion in a text, a canvas as a card waiting to be placed, your app as
a chat's answer or a log.

## Writing one

```elixir
{:ok, stream} =
  Issho.Streams.start(MyApp.Issho, "notebook:7",
    kind: "summary",
    for: ada,
    place: %{"doc" => "notebook:7/intro", "at" => %{"node" => block_id}},
    by: assistant
  )

for chunk <- MyApp.Model.stream(prompt), do: :ok = Issho.Streams.append(stream, chunk)
:ok = Issho.Streams.finish(stream)
```

The process that starts it writes it. If that process exits while the
stream is written, the stream fails (`"writer_exited"`), or finishes with
`on_exit: :finish`, so no stream is left being written forever. Run the
model in a process of its own (a `Task`, an agent's work with
`Issho.Agents.run/5`), not in the LiveView that asked for it: the person
may leave the page, and the answer goes on.

## Who sees it

`:for` is required:

  * a person (an actor, or a key): a private draft, an answer to what
    they asked. Their agents see it too, and so does its writer.
  * `:room`: everyone who may read the room. An agent's report, a
    proposal for everyone to take or leave.
  * `:policy`: whomever your policy allows `:read_stream` in the room
    (`Issho.Policy`), for a rule of your own.

## Reading one

In a LiveView in the room (`Issho.Live.join/4`):

```elixir
def mount(_params, _session, socket) do
  {:ok, outputs} = if connected?(socket), do: Issho.Live.streams(room), else: {:ok, []}
  {:ok, assign(socket, :outputs, Map.new(outputs, &{&1.id, &1}))}
end

def handle_info({Issho, :stream, _id, {:started, stream}}, socket),
  do: {:noreply, update(socket, :outputs, &Map.put(&1, stream.id, stream))}

def handle_info({Issho, :stream, id, {:chunk, text}}, socket),
  do: {:noreply, update(socket, :outputs, &Map.update!(&1, id, fn s -> %{s | content: s.content <> text} end))}

def handle_info({Issho, :stream, id, message}, socket), do: ...
```

`Issho.Live.streams/1` gives the streams the person may see, each with
what it holds so far, and from then on sends the LiveView what comes, in
order, with nothing missed or sent twice: `{:chunk, data}`, `:finished`,
`{:failed, reason}`, `{:closed, outcome}`, `:gone`, and `{:started,
stream}` for a new one. A page that mounts while a stream is written
picks it up where it got to. (These are not LiveView's own streams of a
list, and `:streams` is LiveView's assign.)

Elsewhere (a job, a participant, another node), `Issho.Streams.watch/3`
and `Issho.Streams.subscribe/4` do the same for any process.

## Its end

Finished or failed, a stream is kept for `:keep` milliseconds (the
instance's `:stream_keep`, five minutes), then goes. `close/2` ends it at
once with an outcome you name: a suggestion accepted or rejected, a
report dismissed. From a person's page, `Issho.Live.close_stream/3` first
checks that they may see it:

```elixir
def handle_event("accept", %{"id" => id}, socket) do
  {:ok, stream} = Issho.Streams.get(MyApp.Issho, id)
  :ok = MyApp.Notes.insert(stream.content)
  :ok = Issho.Live.close_stream(room, id, :accepted)
  {:noreply, socket}
end
```

Each start, finish, failure and close is an event of the room:
`"stream.started"`, `"stream.finished"`, `"stream.failed"` and
`"stream.closed"`, with the stream's id, kind, whom it is for, and the
reason or the outcome. An agent waiting on them learns whether its draft
was taken.

## Agents

An agent writes its long answers to a stream for the person it works
for: the `start_stream`, `append_to_stream` and `finish_stream` room
tools. Its stream lives while the agent is in the room.

## Limits

A stream holds at most `:stream_max_bytes` (1 MB; one that would hold more
fails, `"too_large"`), and a room has at most `:room_max_streams` (32) at
once. Streams are kept in memory, as presence is: a stream does not
outlive its node. Each is a process, named in the cluster, so a page on
any node reads it.
