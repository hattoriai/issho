defmodule Issho.StreamsLiveTest do
  # A LiveView's streams: picked up where they got to when it mounts, then
  # as they come; new ones it may see; Accept closes one.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Issho.{Streams, Transaction}

  @endpoint IsshoTest.Endpoint
  @instance IsshoTest.Issho

  setup do
    %{conn: build_conn(), room: "board:" <> Transaction.id()}
  end

  defp page(conn, room, user) do
    {:ok, view, _html} =
      live_isolated(conn, IsshoTest.StreamsLive, session: %{"user" => user, "room" => room})

    view
  end

  test "a page that mounts in the middle picks the stream up where it got to", %{
    conn: conn,
    room: room
  } do
    {:ok, stream} = Streams.start(@instance, room, kind: "summary", for: "user:ada")
    :ok = Streams.append(stream, "The plan ")

    ada = page(conn, room, "user:ada")
    assert ada |> element("#stream-#{stream.id}") |> render() =~ "The plan"

    :ok = Streams.append(stream, "holds.")
    :ok = Streams.finish(stream)
    _ = :sys.get_state(ada.pid)

    html = ada |> element("#stream-#{stream.id}") |> render()
    assert html =~ "The plan holds."
    assert html =~ ~s(data-state="finished")

    # Not Ken's to see.
    ken = page(conn, room, "user:ken")
    refute has_element?(ken, "#stream-#{stream.id}")
  end

  test "a new stream it may see, and Accept", %{conn: conn, room: room} do
    ada = page(conn, room, "user:ada")
    ken = page(conn, room, "user:ken")

    {:ok, mine} = Streams.start(@instance, room, kind: "draft", for: "user:ada")
    {:ok, all} = Streams.start(@instance, room, kind: "report", for: :room)
    :ok = Streams.append(mine, "Take this")
    _ = :sys.get_state(ada.pid)
    _ = :sys.get_state(ken.pid)

    assert ada |> element("#stream-#{mine.id}") |> render() =~ "Take this"
    assert has_element?(ada, "#stream-#{all.id}")
    assert has_element?(ken, "#stream-#{all.id}")
    refute has_element?(ken, "#stream-#{mine.id}")

    ada |> element("#stream-#{mine.id} button") |> render_click()
    assert ada |> element("#closed") |> render() =~ ":ok"
    refute has_element?(ada, "#stream-#{mine.id}")
    assert {:error, :not_found} = Streams.get(@instance, mine.id)

    # Ken may not close what he may not see.
    {:ok, secret} = Streams.start(@instance, room, kind: "draft", for: "user:ada")
    render_hook(ken, "accept", %{"id" => secret.id})
    assert ken |> element("#closed") |> render() =~ ":forbidden"
    assert {:ok, _} = Streams.get(@instance, secret.id)
  end
end
