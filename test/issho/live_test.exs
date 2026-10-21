defmodule Issho.LiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Issho.Transaction

  @endpoint IsshoTest.Endpoint

  setup do
    %{room: "board:" <> Transaction.id(), conn: build_conn()}
  end

  defp board(conn, room, user),
    do: live_isolated(conn, IsshoTest.BoardLive, session: %{"user" => user, "room" => room})

  test "a change in one person's LiveView renders in another's component", %{
    conn: conn,
    room: room
  } do
    {:ok, ada, _} = board(conn, room, "user:ada")
    {:ok, ken, _} = board(conn, room, "user:ken")
    assert render(ken) =~ "Untitled"

    render_click(ada, "rename", %{"title" => "Q3 plan"})

    assert render(ken) =~ "Q3 plan"
    assert render(ada) =~ "Q3 plan"
  end

  test "people come and go, as the components see them", %{conn: conn, room: room} do
    {:ok, ada, _} = board(conn, room, "user:ada")
    {:ok, ken, _} = board(conn, room, "user:ken")
    assert render(ada) =~ "people: 2"

    GenServer.stop(ken.pid)
    Process.sleep(50)
    assert render(ada) =~ "people: 1"
  end

  test "the LiveView itself can receive the room's events", %{conn: conn, room: room} do
    {:ok, ada, _} = board(conn, room, "user:ada")
    {:ok, _ken, _} = board(conn, room, "user:ken")
    Process.sleep(30)
    assert render(ada) =~ "presence_diff"
  end

  test "a revoked person's components hear why", %{conn: conn, room: room} do
    {:ok, ada, _} = board(conn, room, "user:ada")
    Issho.revoke(IsshoTest.Issho, room, "user:ada")
    assert render(ada) =~ "bye: revoked"
  end

  test "Issho.Live without its hook says what to do", %{conn: conn} do
    Process.flag(:trap_exit, true)

    assert {{%ArgumentError{message: message}, _}, _} =
             catch_exit(live_isolated(conn, IsshoTest.UnhookedLive))

    assert message =~ "on_mount Issho.Live"
  end
end
