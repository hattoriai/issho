defmodule Issho.StateTest do
  # Shared state without an engine of your own: a LiveView assign that
  # people, agents and the server change together.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import IsshoTest.Sync

  alias Issho.{Authority, Documents, State, Tool, Tools, Transaction}

  doctest Issho.State

  defmodule Counter do
    @moduledoc false
    # An engine that is not the map's.
    @behaviour Issho.Engine
    def name, do: "counter"
    def version, do: 1
    def init(_initial, _opts), do: {:ok, %{"n" => 0}}
    def apply(state, _ops, _opts), do: {:ok, state}
  end

  @instance IsshoTest.Issho
  @endpoint IsshoTest.Endpoint

  setup do
    %{room: "retro:" <> Transaction.id(), conn: build_conn()}
  end

  defp retro(conn, room, user),
    do: live_isolated(conn, IsshoTest.RetroLive, session: %{"user" => user, "room" => room})

  test "a change in one LiveView is the state of every LiveView of the room", %{
    conn: conn,
    room: room
  } do
    {:ok, ada, _} = retro(conn, room, "user:ada")
    {:ok, ken, _} = retro(conn, room, "user:ken")

    render_click(ada, "add", %{"id" => "c1", "text" => "Plan"})
    render_click(ken, "add", %{"id" => "c2", "text" => "Ship"})
    render_click(ken, "add", %{"id" => "c3", "text" => "Rest", "after" => "c1"})
    render_click(ada, "vote", %{"id" => "c3"})
    render_click(ken, "vote", %{"id" => "c3"})
    render_click(ada, "done", %{"id" => "c2"})

    settle(ada.pid)
    settle(ken.pid)

    for view <- [ada, ken] do
      assert view |> element("#todo") |> render() =~ ~r/Plan:0.*Rest:2/s
      assert view |> element("#done") |> render() =~ "Ship:0"
    end
  end

  test "an agent's change, and the server's", %{conn: conn, room: room} do
    {:ok, ada, _} = retro(conn, room, "user:ada")
    ctx = Tool.Context.new(@instance, %{id: "agent:claude", name: "Claude", kind: :agent})

    ops = [
      %{
        "op" => "insert",
        "path" => ["cols", "todo"],
        "value" => %{"id" => "a1", "text" => "From the agent"}
      }
    ]

    assert {:ok, %{"revision" => _}} =
             Tools.call(Tools.room(), "update_state", %{"room" => room, "ops" => ops}, ctx)

    {:ok, _} =
      Issho.transact(@instance, room, [State.increment(["cols", "todo", "a1", "votes"], 3)])

    settle(ada.pid)
    assert render(ada) =~ "From the agent:3"
  end

  test "a refused change leaves the state as it was", %{conn: conn, room: room} do
    {:ok, ada, _} = retro(conn, room, "user:ada")
    render_click(ada, "bad", %{})
    assert ada |> element("#error") |> render() =~ "invalid_path"
  end

  test "the static render has the default", %{conn: conn, room: room} do
    {:ok, _view, html} = retro(conn, room, "user:ada")
    assert html =~ "static"
  end

  test "after a transaction it missed, the LiveView reads the state again", %{
    conn: conn,
    room: room
  } do
    {:ok, ada, _} = retro(conn, room, "user:ada")
    {:ok, pid} = Documents.open(@instance, room)
    {:ok, %{"epoch" => epoch}} = Authority.snapshot(pid)

    {:ok, %{"revision" => revision}} =
      Issho.transact(@instance, room, [
        State.insert(["cols", "todo"], %{"id" => "x", "text" => "Missed"})
      ])

    settle(ada.pid)

    # A transaction from beyond the next revision: the LiveView missed one.
    send(
      ada.pid,
      {Issho, :transaction, room,
       %{"id" => "t", "epoch" => epoch, "revision" => revision + 5, "ops" => [], "author" => "u"}}
    )

    settle(ada.pid)
    assert render(ada) =~ "Missed:0"

    # One it has already changes nothing.
    send(
      ada.pid,
      {Issho, :transaction, room,
       %{
         "id" => "t",
         "epoch" => epoch,
         "revision" => revision,
         "ops" => [State.set(["cols"], %{})],
         "author" => "u"
       }}
    )

    settle(ada.pid)
    assert render(ada) =~ "Missed:0"
  end

  test "update_state refuses a document that is not shared state" do
    room = "canvas:" <> Transaction.id()

    spec = %{engine: Counter, initial: nil, store: :none}
    {:ok, _} = Documents.open(@instance, room, nil, spec: spec)

    ctx = Tool.Context.new(@instance, %{id: "agent:claude", name: "Claude", kind: :agent})

    assert {:error, "That document is counter's" <> _} =
             Tools.call(Tools.room(), "update_state", %{"room" => room, "ops" => []}, ctx)
  end

  test "a map document of version 1 opens with version 2" do
    id = "canvas:" <> Transaction.id()
    store = start_supervised!({Issho.Store.Memory, name: :"store_#{System.unique_integer()}"})

    stored = %{
      "engine" => "map",
      "engine_version" => 1,
      "epoch" => "e1",
      "revision" => 3,
      "state" => %{"a" => 1},
      "initial" => %{},
      "journal" => [],
      "receipts" => %{}
    }

    Agent.update(store, &Map.put(&1, id, %{document: stored, content: nil}))
    spec = %{engine: Issho.Engine.Map, store: {Issho.Store.Memory, store}}
    {:ok, pid} = Documents.open(@instance, id, nil, spec: spec)

    assert {:ok, %{"epoch" => "e1", "revision" => 3, "state" => %{"a" => 1}}} =
             Authority.snapshot(pid)
  end
end
