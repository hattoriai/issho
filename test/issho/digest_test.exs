defmodule Issho.DigestTest do
  # What an agent heard, as a digest: bursts of selections and typing as
  # one entry each, the important events one by one and never pushed out
  # by a burst, and what went said, not hidden.
  use ExUnit.Case, async: true

  alias Issho.{Digest, Event, Identity}

  @room "board:1"

  defp who(key),
    do: Identity.new(%{id: key, name: String.capitalize(String.replace(key, "user:", ""))})

  defp event(name, opts) do
    %Event{
      name: name,
      room: @room,
      document: opts[:document],
      by: opts[:by] && who(opts[:by]),
      data: Keyword.get(opts, :data, %{}),
      at: DateTime.utc_now()
    }
  end

  defp selection(by, session, at),
    do:
      event("selection.changed",
        by: by,
        data: %{place: %{"doc" => @room, "at" => at}, session: session}
      )

  defp changed(by, revision),
    do: event("document.changed", by: by, document: @room, data: %{revision: revision})

  defp comment(n, opts \\ []),
    do:
      event("comment.created",
        by: "user:ken",
        data: Map.merge(%{comment: "c#{n}"}, Map.new(opts))
      )

  defp keep_all(events, digest \\ Digest.new(), coalesce \\ %{}),
    do: Enum.reduce(events, digest, &Digest.keep(&2, &1, coalesce))

  defp all(_event), do: true

  test "a burst of selections is one entry for each person's session: the latest, and how many" do
    digest =
      keep_all(
        for(n <- 1..30, do: selection("user:ada", "s1", n)) ++
          for(n <- 1..5, do: selection("user:ken", "s2", n))
      )

    {[ada, ken], digest} = Digest.take(digest, &all/1, :digest, @room)

    assert %{
             name: "selection.changed",
             by: %{key: "user:ada"},
             data: %{count: 30, place: %{"at" => 30}}
           } = ada

    assert %{by: %{key: "user:ken"}, data: %{count: 5, place: %{"at" => 5}}} = ken
    assert {[], _} = Digest.take(digest, &all/1, :digest, @room)
  end

  test "typing is one change of each document: from which revision, to which, how many, by whom" do
    digest =
      keep_all(
        for(n <- 1..40, do: changed(if(rem(n, 2) == 0, do: "user:ada", else: "user:ken"), n)) ++
          [
            event("document.changed",
              by: "user:ada",
              document: @room <> "/body",
              data: %{revision: 7}
            )
          ]
      )

    {[board, body], _} = Digest.take(digest, &all/1, :digest, @room)

    assert %{
             document: @room,
             data: %{revision: 40, from_revision: 1, count: 40, authors: authors}
           } = board

    assert Enum.sort(authors) == ["Ada", "Ken"]
    assert %{document: "board:1/body", data: %{revision: 7, count: 1}} = body
  end

  test "its authors are bounded" do
    digest = keep_all(for n <- 1..20, do: changed("user:p#{n}", n))
    {[%{data: %{authors: authors, count: 20}}], _} = Digest.take(digest, &all/1, :digest, @room)
    assert length(authors) == 5
  end

  test "a mention in the middle of a long burst is not pushed out, and comes in its order" do
    mention = comment(1, mentions: ["agent:claude"])

    digest =
      keep_all(
        for(n <- 1..500, do: selection("user:ada", "s1", n)) ++
          [mention] ++ for(n <- 1..500, do: changed("user:ada", n))
      )

    {events, _} = Digest.take(digest, &all/1, :digest, @room)
    names = Enum.map(events, & &1.name)
    assert "comment.created" in names
    # The routine queue overflowed, and says so: look again.
    assert hd(names) == "events.dropped"
    assert %{data: %{routine: dropped, important: 0}} = hd(events)
    assert dropped > 0
  end

  test "too many important events: the oldest go, and it is told how many" do
    digest = keep_all(for n <- 1..150, do: comment(n))
    {[gap | events], digest} = Digest.take(digest, &all/1, :digest, @room)

    assert %{name: "events.dropped", data: %{count: 50, important: 50, routine: 0}} = gap
    assert length(events) == 100
    assert hd(events).data.comment == "c51"

    # Told once.
    digest = keep_all([comment(151)], digest)
    assert {[%{name: "comment.created"}], _} = Digest.take(digest, &all/1, :digest, @room)
  end

  test "taken raw, each event as it was, oldest first" do
    events = [
      selection("user:ada", "s1", 1),
      comment(1),
      selection("user:ada", "s1", 2),
      changed("user:ada", 1)
    ]

    {taken, _} = Digest.take(keep_all(events), &all/1, :raw, @room)
    assert taken == events
  end

  test "only those it wants are taken; the others stay" do
    digest = keep_all([selection("user:ada", "s1", 1), comment(1), changed("user:ada", 1)])

    {[%{name: "comment.created"}], digest} =
      Digest.take(digest, &(&1.name == "comment.created"), :digest, @room)

    {rest, _} = Digest.take(digest, &all/1, :digest, @room)
    assert Enum.map(rest, & &1.name) == ["selection.changed", "document.changed"]
  end

  test "the app's own names coalesce by the keys it declares; a mention never does" do
    coalesce = %{"retro.voted" => [:card]}

    vote = fn card, n ->
      event("retro.voted", by: "user:ada", document: @room, data: %{card: card, votes: n})
    end

    digest =
      keep_all(
        [vote.("c1", 1), vote.("c1", 2), vote.("c2", 1), vote.("c1", 3)] ++
          [event("retro.voted", data: %{card: "c1", mentions: ["agent:claude"]})],
        Digest.new(),
        coalesce
      )

    {events, _} = Digest.take(digest, &all/1, :digest, @room, coalesce)

    assert length(events) == 3

    assert %{data: %{votes: 3, count: 3}} =
             Enum.find(events, &(&1.data[:card] == "c1" and !&1.data[:mentions]))

    assert %{data: %{count: 1}} = Enum.find(events, &(&1.data[:card] == "c2"))
    assert Enum.any?(events, &(&1.data[:mentions] == ["agent:claude"]))
  end
end
