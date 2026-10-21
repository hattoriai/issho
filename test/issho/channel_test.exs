defmodule Issho.ChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias Issho.{Token, Transaction}

  @endpoint IsshoTest.Endpoint
  @instance IsshoTest.Issho

  setup do
    %{room: "board:" <> Transaction.id()}
  end

  defp enter(room, actor, opts \\ []) do
    token = Token.sign(@instance, actor, room, opts)

    socket(IsshoTest.Socket)
    |> subscribe_and_join(IsshoTest.Channel, "issho:" <> room, %{"token" => token})
  end

  defp tx(snapshot, ops) do
    %{
      "id" => Transaction.id(),
      "epoch" => snapshot["epoch"],
      "base_revision" => snapshot["revision"],
      "ops" => ops
    }
  end

  @ada %{id: "user:ada", name: "Ada"}
  @ken %{id: "user:ken", name: "Kenji", color: "#e84a1c"}

  test "joins with a token and receives the room's people", %{room: room} do
    assert {:ok, %{"session" => session, "can" => "write"}, _socket} = enter(room, @ada)
    assert is_binary(session)
    assert_push "presence_state", people

    assert %{"user:ada" => %{metas: [%{"name" => "Ada", "kind" => "human", "can" => "write"}]}} =
             people
  end

  test "refuses a token of another room, a bad token and a denied actor", %{room: room} do
    other = Token.sign(@instance, @ada, "board:other")

    assert {:error, %{"reason" => "forbidden"}} =
             socket(IsshoTest.Socket)
             |> subscribe_and_join(IsshoTest.Channel, "issho:" <> room, %{"token" => other})

    assert {:error, %{"reason" => "forbidden"}} =
             socket(IsshoTest.Socket)
             |> subscribe_and_join(IsshoTest.Channel, "issho:" <> room, %{"token" => "nope"})

    IsshoTest.Policy.deny("user:denied")
    on_exit(fn -> IsshoTest.Policy.allow("user:denied") end)
    assert {:error, %{"reason" => "forbidden"}} = enter(room, %{id: "user:denied"})
  end

  test "opens a document, commits, and the others receive the change", %{room: room} do
    {:ok, _, ada} = enter(room, @ada)
    {:ok, _, ken} = enter(room, @ken)

    ref = push(ada, "open", %{"doc" => room})
    assert_reply ref, :ok, %{"revision" => 0, "state" => %{"title" => "Untitled"}} = snapshot
    ref = push(ken, "open", %{"doc" => room})
    assert_reply ref, :ok, _

    t = tx(snapshot, [%{"op" => "set", "path" => ["title"], "value" => "Plan"}])
    ref = push(ada, "tx", %{"doc" => room, "tx" => t})
    assert_reply ref, :ok, %{"revision" => 1}

    # Both sessions push the accepted transaction to their browser.
    assert_push "tx", %{"doc" => ^room, "event" => %{"revision" => 1, "author" => "user:ada"}}
    assert_push "tx", %{"doc" => ^room, "event" => %{"revision" => 1}}
  end

  test "nested documents of the room open; another room's do not", %{room: room} do
    {:ok, _, ada} = enter(room, @ada)
    ref = push(ada, "open", %{"doc" => room <> "/n7/body"})
    assert_reply ref, :ok, %{"state" => %{"doc" => doc}}
    assert doc == room <> "/n7/body"

    ref = push(ada, "open", %{"doc" => "board:elsewhere"})
    assert_reply ref, :error, %{"reason" => "other_room"}
  end

  test "a read token never writes", %{room: room} do
    {:ok, _, ada} = enter(room, @ada, can: :read)
    ref = push(ada, "open", %{"doc" => room})
    assert_reply ref, :ok, snapshot

    ref =
      push(ada, "tx", %{
        "doc" => room,
        "tx" => tx(snapshot, [%{"op" => "delete", "path" => ["title"]}])
      })

    assert_reply ref, :error, %{"reason" => "read_only"}
  end

  test "the policy refuses writes in a read-only room", %{room: _room} do
    room = "readonly:" <> Transaction.id()
    {:ok, _, ada} = enter(room, @ada)
    ref = push(ada, "open", %{"doc" => room})
    assert_reply ref, :ok, snapshot

    ref =
      push(ada, "tx", %{
        "doc" => room,
        "tx" => tx(snapshot, [%{"op" => "delete", "path" => ["title"]}])
      })

    assert_reply ref, :error, %{"reason" => "forbidden"}
  end

  test "awareness reaches the others in batched frames, not the sender", %{room: room} do
    {:ok, %{"session" => ada_session}, ada} = enter(room, @ada)
    {:ok, %{"session" => ken_session}, ken} = enter(room, @ken)

    for socket <- [ada, ken] do
      ref = push(socket, "open", %{"doc" => room})
      assert_reply ref, :ok, _
    end

    place = %{"doc" => room, "at" => %{"path" => ["title"]}}
    ref = push(ada, "aware", %{"state" => %{"place" => place}})
    assert_reply ref, :ok

    # Ken's session pushes Ada's state; Ada's session skips her own.
    assert_push "aware", %{"states" => states}, 500
    assert %{^ada_session => %{"key" => "user:ada", "state" => %{"place" => ^place}}} = states
    refute Map.has_key?(states, ken_session)
  end

  test "refuses places the binding does not draw, and places in another room", %{room: room} do
    {:ok, _, ada} = enter(room, @ada)
    ref = push(ada, "open", %{"doc" => room})
    assert_reply ref, :ok, _

    ref = push(ada, "aware", %{"state" => %{"place" => %{"doc" => room, "at" => %{"x" => 1}}}})
    assert_reply ref, :error, %{"reason" => "invalid_place"}

    ref = push(ada, "aware", %{"state" => %{"place" => %{"doc" => "board:x", "at" => %{}}}})
    assert_reply ref, :error, %{"reason" => "other_room"}
  end

  test "revoking an actor ends its sessions", %{room: room} do
    {:ok, _, ada} = enter(room, @ada)
    Process.unlink(ada.channel_pid)
    ref = Process.monitor(ada.channel_pid)

    Issho.revoke(@instance, room, @ada)
    assert_push "bye", %{"reason" => "revoked"}
    assert_receive {:DOWN, ^ref, :process, _, :normal}
  end

  test "a session whose access is taken away stops receiving changes", %{room: room} do
    actor = %{id: "user:soon-denied"}
    {:ok, _, ada} = enter(room, actor)
    Process.unlink(ada.channel_pid)
    ref = Process.monitor(ada.channel_pid)
    push(ada, "open", %{"doc" => room}) |> assert_reply(:ok, _)

    IsshoTest.Policy.deny(actor.id)
    on_exit(fn -> IsshoTest.Policy.allow(actor.id) end)

    {:ok, _} = Issho.transact(@instance, room, [%{"op" => "set", "path" => ["x"], "value" => 1}])
    assert_push "bye", %{"reason" => "unauthorized"}
    refute_push "tx", _
    assert_receive {:DOWN, ^ref, :process, _, :normal}
  end
end
