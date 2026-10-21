defmodule Issho.ParticipantTest do
  use ExUnit.Case, async: false

  alias Issho.{Participant, Presence, Transaction}

  @instance IsshoTest.Issho

  setup do
    %{room: "board:" <> Transaction.id()}
  end

  @ada %{id: "user:ada", name: "Ada"}
  @claude %{id: "agent:claude", name: "Claude", kind: :agent}

  test "an agent joins on behalf of a person, and people see it as an agent", %{room: room} do
    {:ok, claude} = Issho.join_as(@instance, @claude, room, on_behalf_of: @ada)
    assert Process.alive?(claude)

    assert %{"agent:claude" => meta} = Presence.people(room)
    assert meta["kind"] == "agent"
    assert meta["on_behalf_of"]["key"] == "user:ada"
  end

  test "transacts with operations only; Issho builds the envelope", %{room: room} do
    {:ok, claude} = Issho.join_as(@instance, @claude, room)
    {:ok, %{"revision" => 0}} = Participant.open(claude, room)

    assert {:ok, %{"revision" => 1}} =
             Participant.transact(claude, room, [
               %{"op" => "set", "path" => ["title"], "value" => "Draft"}
             ])

    assert_receive {Participant, ^claude, "tx", %{"event" => %{"author" => "agent:claude"}}}
    assert {:ok, %{"state" => %{"title" => "Draft"}}} = Participant.read(claude, room)
  end

  test "an agent sees a person's lock before it acts", %{room: room} do
    {:ok, ada} = Issho.join_as(@instance, @ada, room)
    {:ok, claude} = Issho.join_as(@instance, @claude, room)
    {:ok, _} = Participant.open(ada, room)

    place = %{"doc" => room, "at" => %{"path" => ["title"]}}
    # Ada's state reaches the room's awareness before lock/2 returns, so
    # Claude sees the lock at once, and its release.
    :ok = Participant.lock(ada, [place])
    assert [{^place, "user:ada"}] = Participant.locks(claude)

    :ok = Participant.lock(ada, [])
    assert Participant.locks(claude) == []
  end

  test "a read-only agent cannot lock or write", %{room: room} do
    {:ok, claude} = Issho.join_as(@instance, @claude, room, can: :read)
    {:ok, _} = Participant.open(claude, room)

    assert {:error, :read_only} =
             Participant.lock(claude, [%{"doc" => room, "at" => %{"path" => ["a"]}}])

    assert {:error, :read_only} =
             Participant.transact(claude, room, [%{"op" => "delete", "path" => ["a"]}])
  end

  test "asks the room's policy for a write it makes itself, outside the documents",
       %{room: room} do
    {:ok, writer} = Issho.join_as(@instance, @claude, room)
    {:ok, reader} = Issho.join_as(@instance, %{@claude | id: "agent:reader"}, room, can: :read)

    assert Participant.authorize(writer, :write) == :ok
    assert Participant.authorize(reader, :read) == :ok
    assert Participant.authorize(reader, :write) == {:error, :read_only}
  end

  test "an agent's leaving takes it out of the room", %{room: room} do
    {:ok, claude} = Issho.join_as(@instance, @claude, room)
    assert Map.has_key?(Presence.people(room), "agent:claude")
    Phoenix.PubSub.subscribe(IsshoTest.PubSub, Presence.topic(room))

    :ok = Participant.leave(claude)

    assert_receive %Phoenix.Socket.Broadcast{
      event: "presence_diff",
      payload: %{leaves: %{"agent:claude" => _}}
    }

    refute Map.has_key?(Presence.people(room), "agent:claude")
  end
end
