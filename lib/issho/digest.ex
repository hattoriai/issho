defmodule Issho.Digest do
  @moduledoc """
  What an agent heard in a room since it last took it, as a digest: what
  happened, not every moment of it (`Issho.Agents.wait/6`, the
  `wait_for_events` tool).

  An agent keeps the room's events in two bounded queues:

    * **routine** events, which come in bursts and say where things are
      now: `"selection.changed"`, `"document.changed"`, and the app's own
      names it declares (the instance's `:coalesce`, below);
    * every other event, one by one: comments, requests, interruptions,
      people coming and going, streams, and the app's own.

  A burst of routine events never pushes out a comment that mentions the
  agent: each queue has its own room (100 events, and 400).

  Taken as a digest (the default), routine events of the same thing come
  as one:

    * `"selection.changed"`, one for each person's session: the latest
      place, and `count`;
    * `"document.changed"`, one for each document: its latest `revision`,
      the `from_revision` it began at, `count`, and `authors` (their
      names, at most five);
    * an app's own name, one for each value of the data keys it declared:
      the latest, and `count`.

  Taken raw (`every: true`), they come as they were, oldest first.

  When a queue was full, the oldest events of it went: the agent is told,
  with an `"events.dropped"` event (`data`: `%{count: n, important: n,
  routine: n}`), that it should look again (`look_around`,
  `read_document`), never that it heard everything.

  ## The app's own names

      {Issho, name: MyApp.Issho, coalesce: %{"retro.voted" => [:card]}, ...}

  coalesces `"retro.voted"` events of the same `card` (a key of their
  `data`) and the same document. An event that mentions someone is never
  coalesced.

  The queues are the agent's own, of the events the room let it hear: a
  digest never puts together events of different audiences.
  """

  alias Issho.Event

  @important 100
  @routine 400
  @authors 5

  defstruct seq: 0, important: [], routine: [], dropped: %{important: 0, routine: 0}

  @type t :: %__MODULE__{}

  @doc "An empty digest."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Keeps an event, in its queue; the oldest of a full queue goes, and is counted."
  @spec keep(t(), Event.t(), map()) :: t()
  def keep(%__MODULE__{} = digest, %Event{} = event, coalesce \\ %{}) do
    seq = digest.seq + 1
    queue = if key(event, coalesce), do: :routine, else: :important
    bound = if queue == :routine, do: @routine, else: @important
    items = Map.fetch!(digest, queue) ++ [{seq, event}]
    over = max(length(items) - bound, 0)

    digest
    |> Map.put(:seq, seq)
    |> Map.put(queue, Enum.drop(items, over))
    |> update_in([Access.key(:dropped), queue], &(&1 + over))
  end

  @doc """
  The events kept that `wanted?` wants, as a digest (`:digest`) or as
  they were (`:raw`), oldest first, and what remains. An `"events.dropped"`
  comes first when events it might have wanted went.
  """
  @spec take(t(), (Event.t() -> boolean()), :digest | :raw, String.t(), map()) ::
          {[Event.t()], t()}
  def take(%__MODULE__{} = digest, wanted?, mode, room, coalesce \\ %{}) do
    {important, kept_important} = Enum.split_with(digest.important, fn {_, e} -> wanted?.(e) end)
    {routine, kept_routine} = Enum.split_with(digest.routine, fn {_, e} -> wanted?.(e) end)

    {gap, dropped} = gap(digest.dropped, important, routine, room)

    entries =
      case mode do
        :raw -> important ++ routine
        :digest -> important ++ coalesced(routine, coalesce)
      end

    events = entries |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

    {gap ++ events,
     %{digest | important: kept_important, routine: kept_routine, dropped: dropped}}
  end

  # Told of what went: always of important events; of routine ones when
  # it takes routine events, which those would have been.
  defp gap(%{important: i, routine: r} = dropped, _important, routine, room) do
    told_r = if routine != [], do: r, else: 0

    if i + told_r == 0 do
      {[], dropped}
    else
      event = %Event{
        name: "events.dropped",
        room: room,
        data: %{count: i + told_r, important: i, routine: told_r},
        at: DateTime.utc_now()
      }

      {[event], %{dropped | important: 0, routine: r - told_r}}
    end
  end

  # One entry for each thing: the latest, with what it stands for.
  defp coalesced(routine, coalesce) do
    routine
    |> Enum.group_by(fn {_seq, event} -> key(event, coalesce) end)
    |> Enum.map(fn {_key, items} ->
      {seq, latest} = List.last(items)
      {seq, %{latest | data: summary(latest, Enum.map(items, &elem(&1, 1)))}}
    end)
  end

  defp summary(%Event{name: "document.changed", data: data}, events) do
    first = hd(events)

    authors =
      events
      |> Enum.map(&(&1.by && (&1.by.name || &1.by.key)))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(@authors)

    Map.merge(data, %{
      from_revision: first.data[:revision],
      count: length(events),
      authors: authors
    })
  end

  defp summary(%Event{data: data}, events), do: Map.put(data, :count, length(events))

  # What a routine event is of, or nil for one that comes one by one.
  defp key(%Event{data: data} = event, coalesce) do
    if mentions?(data), do: nil, else: key_of(event, coalesce)
  end

  defp key_of(%Event{name: "selection.changed", by: by, data: data}, _coalesce),
    do: {"selection.changed", by && by.key, data[:session]}

  defp key_of(%Event{name: "document.changed", document: document}, _coalesce),
    do: {"document.changed", document}

  defp key_of(%Event{name: name, document: document, data: data}, coalesce) do
    case Map.get(coalesce, name) do
      nil -> nil
      fields -> {name, document, Enum.map(fields, &value(data, &1))}
    end
  end

  defp mentions?(data), do: List.wrap(data[:mentions] || data["mentions"]) != []

  defp value(data, field) when is_atom(field), do: data[field] || data[Atom.to_string(field)]
  defp value(data, field), do: data[field]
end
