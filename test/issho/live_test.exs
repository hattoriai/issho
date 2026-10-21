defmodule Issho.LiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  import IsshoTest.Sync

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

  # Presence sends its diffs to every subscriber at once: once the test has
  # one, so has each LiveView, and settle/1 waits for it to be handled.
  test "people come and go, as the components see them", %{conn: conn, room: room} do
    Phoenix.PubSub.subscribe(IsshoTest.PubSub, Issho.Presence.topic(room))
    {:ok, ada, _} = board(conn, room, "user:ada")
    {:ok, ken, _} = board(conn, room, "user:ken")

    assert_receive %Phoenix.Socket.Broadcast{
      event: "presence_diff",
      payload: %{joins: %{"user:ken" => _}}
    }

    settle(ada.pid)
    assert render(ada) =~ "people: 2"

    GenServer.stop(ken.pid)

    assert_receive %Phoenix.Socket.Broadcast{
      event: "presence_diff",
      payload: %{leaves: %{"user:ken" => _}}
    }

    settle(ada.pid)
    assert render(ada) =~ "people: 1"
  end

  test "the LiveView itself can receive the room's events", %{conn: conn, room: room} do
    Phoenix.PubSub.subscribe(IsshoTest.PubSub, Issho.Presence.topic(room))
    {:ok, ada, _} = board(conn, room, "user:ada")
    {:ok, _ken, _} = board(conn, room, "user:ken")

    assert_receive %Phoenix.Socket.Broadcast{
      event: "presence_diff",
      payload: %{joins: %{"user:ken" => _}}
    }

    settle(ada.pid)
    assert render(ada) =~ "presence_diff"
  end

  describe "release" do
    test "a component released while the LiveView listens keeps it in the room", %{
      conn: conn,
      room: room
    } do
      {:ok, ken, _} = board(conn, room, "user:ken")
      render_click(ken, "release", %{})

      assert Map.has_key?(Issho.Presence.list(Issho.Presence.topic(room)), "user:ken")
    end

    test "the last one released, the LiveView leaves the room and its document", %{
      conn: conn,
      room: room
    } do
      Phoenix.PubSub.subscribe(IsshoTest.PubSub, Issho.Presence.topic(room))
      {:ok, ada, _} = board(conn, room, "user:ada")
      {:ok, ken, _} = board(conn, room, "user:ken")
      assert_receive %Phoenix.Socket.Broadcast{payload: %{joins: %{"user:ken" => _}}}

      render_click(ken, "release", %{"self" => "true"})

      assert_receive %Phoenix.Socket.Broadcast{payload: %{leaves: %{"user:ken" => _}}}
      settle(ada.pid)
      assert render(ada) =~ "people: 1"

      # Ken's LiveView goes on, and hears the room no more.
      render_click(ada, "rename", %{"title" => "Q3 plan"})
      settle(ken.pid)
      assert Process.alive?(ken.pid)
      refute render(ken) =~ "Q3 plan"
    end

    test "a released document lets its authority go", %{conn: conn, room: room} do
      {:ok, ken, _} = board(conn, room, "user:ken")
      pid = Issho.Documents.whereis(IsshoTest.Issho, room)
      assert map_size(:sys.get_state(pid).members) == 1

      render_click(ken, "release", %{"self" => "true"})

      assert map_size(:sys.get_state(pid).members) == 0
    end
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

  describe "grants" do
    defp granted(conn, room, user),
      do: live_isolated(conn, IsshoTest.GrantLive, session: %{"user" => user, "room" => room})

    test "the LiveView renews the grant of its room while the policy lets the actor in",
         %{conn: conn, room: room} do
      {:ok, view, _html} = granted(conn, room, "user:grantee")

      render_hook(view, "issho:grant", %{"room" => room})

      assert_reply(view, %{
        "room" => ^room,
        "token" => token,
        "can" => "read",
        "self" => "user:grantee"
      })

      assert {:ok, %Issho.Identity{key: "user:grantee"}, :read} =
               Issho.Token.verify(IsshoTest.Issho, token, room)

      # A room it never granted, and an actor the policy no longer lets in, get nothing.
      render_hook(view, "issho:grant", %{"room" => "board:other"})
      assert_reply(view, reply)
      assert reply == %{}

      IsshoTest.Policy.deny("user:grantee")
      on_exit(fn -> IsshoTest.Policy.allow("user:grantee") end)
      render_hook(view, "issho:grant", %{"room" => room})
      assert_reply(view, reply)
      assert reply == %{}
    end
  end
end
