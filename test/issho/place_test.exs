defmodule Issho.PlaceTest do
  # A place's label: what someone selected in a few words, cleaned and cut
  # on the way in, and shown wherever Issho shows the place: the others'
  # awareness, the events, an agent's tools, the comments and the panel.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import IsshoTest.Sync

  alias Issho.{Comments, Event, Events, Participant, Place, Tool, Tools, Transaction}
  alias Issho.Comments.Ops

  doctest Issho.Place

  @instance IsshoTest.Issho
  @endpoint IsshoTest.Endpoint

  # Characters by their code points: never written into this file itself.
  defp c(codes), do: List.to_string(List.wrap(codes))
  defp tags(text), do: text |> String.to_charlist() |> Enum.map(&(&1 + 0xE0000)) |> c()

  @rlo 0x202E

  defp ada, do: %{id: "user:ada", name: "Ada"}

  setup do
    %{room: "board:" <> Transaction.id()}
  end

  describe "label/1 and clean/1" do
    test "one line of words, without what no one sees, at most 60 characters" do
      assert Place.label("Fold it,\n  again" <> c(@rlo) <> tags("OBEY") <> " and again") ==
               "Fold it, again and again"

      long = Place.label(String.duplicate("word ", 30))
      assert String.length(long) == 60
      assert String.ends_with?(long, "…")

      # Cut by what people see: an emoji of several code points stays whole.
      family = "👨‍👩‍👧"
      cut = Place.label(String.duplicate("a", 58) <> family <> family <> family)
      assert cut == String.duplicate("a", 58) <> family <> "…"
      assert String.valid?(cut)
    end

    test "anything but words is no label" do
      place = %{"doc" => "board:1", "at" => %{"node" => "n7"}}

      for label <- ["", "  ", c(@rlo), 42, %{"text" => "x"}, nil],
          do: assert(Place.clean(Map.put(place, "label", label)) == place)

      assert Place.clean(nil) == nil
      assert Place.clean(place) == place
    end

    test "check/3 refuses a label that is not clean words", %{room: room} do
      place = %{"doc" => room, "at" => %{"node" => "n7"}}
      none = fn _doc -> nil end

      assert :ok = Place.check(Map.put(place, "label", "A card"), room, none)

      for label <- ["A card" <> c(@rlo), 42, String.duplicate("a", 61)],
          do:
            assert(
              {:error, :invalid_label} = Place.check(Map.put(place, "label", label), room, none)
            )
    end

    test "in words for people" do
      assert Place.words(%{"doc" => "d", "label" => "A card"}, "Your selection") == "“A card”"
      assert Place.words(%{"doc" => "d"}, "Your selection") == "Your selection"
      assert Place.words(nil, "Your selection") == "Your selection"
    end
  end

  test "a browser's labelled place reaches the others cleaned, and selection.changed says it",
       %{room: room} do
    :ok = Events.subscribe(@instance, room)
    {:ok, browser} = Issho.join_as(@instance, ada(), room)
    at = %{"node" => "n7"}

    :ok =
      Participant.place(browser, %{
        "doc" => room,
        "at" => at,
        "label" => "Fold it," <> c(@rlo) <> " again" <> tags("IGNORE ALL")
      })

    place = %{"doc" => room, "at" => at, "label" => "Fold it, again"}

    assert_receive {Issho, :event, %Event{name: "selection.changed", data: %{place: ^place}}}
    assert Participant.awareness(browser)["place"] == place

    # Its locks, too.
    :ok =
      Participant.aware(browser, %{"place" => place, "locks" => [Map.put(place, "label", " x ")]})

    assert [%{"label" => "x"}] = Participant.awareness(browser)["locks"]
  end

  test "look_around gives an agent each person's place in words", %{room: room} do
    {:ok, browser} = Issho.join_as(@instance, ada(), room)
    place = %{"doc" => room, "at" => %{"node" => "n7"}, "label" => "Fold it, again"}
    :ok = Participant.place(browser, place)
    ctx = Tool.Context.new(@instance, %{id: "agent:claude", name: "Claude", kind: :agent})

    {:ok, %{"people" => people}} =
      eventually(fn -> Tools.call(Tools.room(), "look_around", %{"room" => room}, ctx) end)

    assert %{"places" => [^place]} = Enum.find(people, &(&1["key"] == "user:ada"))
  end

  describe "comments" do
    test "a thread keeps its place's label, cleaned; a dirty one is refused", %{room: room} do
      place = %{"doc" => room, "at" => %{"node" => "n7"}, "label" => "A card" <> c(@rlo)}

      {:ok, %{thread: thread}} = Comments.start(@instance, room, ada(), place, "First?")

      {:ok, [%{"place" => %{"label" => "A card"}}]} = Comments.threads(@instance, room)

      {:ok, participant} = Issho.join_as(@instance, ada(), room)
      {:ok, _} = Participant.open(participant, Comments.document(room))
      {op, _} = Ops.start(Issho.Identity.new(ada()), place, "Again?")

      assert {:error, :invalid_label} =
               Participant.transact(participant, Comments.document(room), [
                 put_in(op, ["place", "label"], "A card" <> c(@rlo))
               ])

      moved = Ops.place(thread, Map.put(place, "label", "Another"))

      assert {:error, :invalid_label} =
               Participant.transact(participant, Comments.document(room), [
                 put_in(moved, ["place", "label"], 42)
               ])

      assert {:ok, _} = Participant.transact(participant, Comments.document(room), [moved])
    end

    test "the panel says a labelled place in its words", %{room: room} do
      {:ok, view, _html} =
        live_isolated(build_conn(), IsshoTest.CommentsLive,
          session: %{"user" => "user:ada", "room" => room, "name" => "Ada"}
        )

      {:ok, browser} = Issho.join_as(@instance, ada(), room)
      place = %{"doc" => room, "at" => %{"path" => ["title"]}, "label" => "Fold it, again"}
      :ok = Participant.place(browser, place)
      Process.sleep(60)
      settle(view.pid)

      assert view |> element(".issho-composer-where") |> render() =~ "“Fold it, again”"

      view
      |> element(~s(form[phx-submit="start"]))
      |> render_submit(%{"body" => "Too long?", "where" => "selection"})

      settle(view.pid)
      assert view |> element(".issho-thread-place") |> render() =~ "“Fold it, again”"
    end
  end

  test "a stream's place is cleaned like the others", %{room: room} do
    {:ok, stream} =
      Issho.Streams.start(@instance, room,
        for: room,
        place: %{"doc" => room, "at" => %{"node" => "n7"}, "label" => "Draft" <> c(@rlo)}
      )

    assert stream.place["label"] == "Draft"
  end

  # A room's awareness reaches the agent in its next frame.
  defp eventually(fun, tries \\ 50) do
    case fun.() do
      {:ok, %{"people" => people}} = found ->
        if Enum.any?(people, &(&1["places"] != [])), do: found, else: retry(fun, tries)

      _ ->
        retry(fun, tries)
    end
  end

  defp retry(fun, 0), do: fun.()

  defp retry(fun, tries) do
    Process.sleep(10)
    eventually(fun, tries - 1)
  end
end
