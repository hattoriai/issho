defmodule Issho.ParticipantTest do
  use ExUnit.Case, async: false

  import IsshoTest.Eventually

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
    :ok = Participant.lock(ada, [place])

    # Claude's process receives Ada's frame, and the room's locks show it.
    eventually(do: assert([{^place, "user:ada"}] = Participant.locks(claude)))

    :ok = Participant.lock(ada, [])
    eventually(do: assert(Participant.locks(claude) == []))
  end

  test "a read-only agent cannot lock or write", %{room: room} do
    {:ok, claude} = Issho.join_as(@instance, @claude, room, can: :read)
    {:ok, _} = Participant.open(claude, room)

    assert {:error, :read_only} =
             Participant.lock(claude, [%{"doc" => room, "at" => %{"path" => ["a"]}}])

    assert {:error, :read_only} =
             Participant.transact(claude, room, [%{"op" => "delete", "path" => ["a"]}])
  end

  test "an agent's leaving takes it out of the room", %{room: room} do
    {:ok, claude} = Issho.join_as(@instance, @claude, room)
    assert Map.has_key?(Presence.people(room), "agent:claude")
    :ok = Participant.leave(claude)
    eventually(do: refute(Map.has_key?(Presence.people(room), "agent:claude")))
  end
end
