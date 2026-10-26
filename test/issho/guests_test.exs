defmodule Issho.GuestsTest do
  # A visitor no one knows: one key for its session, a guest to the
  # policy, never a writer whatever the policy says, and its comments
  # and requests counted.
  use ExUnit.Case, async: false

  alias Issho.{Comments, Guests, Identity, Participant, Policy, Requests, Transaction}

  @instance IsshoTest.Issho

  setup do
    %{room: "board:" <> Transaction.id(), guest: Guests.new()}
  end

  test "a guest keeps its key, is a guest to the policy, and is seen as one", %{guest: guest} do
    assert %{id: "guest:" <> _, name: "Visitor", kind: :guest} = guest
    assert Guests.new(guest.id, "Ana") == %{id: guest.id, name: "Ana", kind: :guest}
    refute Guests.new("user:ada").id == "user:ada"

    identity = Identity.new(guest)
    assert identity.kind == :guest
    assert identity |> Identity.to_claims() |> Identity.from_claims() |> Map.get(:kind) == :guest
  end

  test "a guest never writes, locks or interrupts, whatever the policy says", %{
    room: room,
    guest: guest
  } do
    identity = Identity.new(guest)

    for action <- [:write, :lock, :interrupt],
        do:
          assert(
            {:error, :forbidden} = Policy.authorize(IsshoTest.Policy, identity, room, action)
          )

    assert :ok = Policy.authorize(IsshoTest.Policy, identity, room, :read)
    assert :ok = Policy.authorize(IsshoTest.Policy, identity, room, :comment)

    {:ok, visitor} = Issho.join_as(@instance, guest, room, can: :write)
    {:ok, _} = Participant.open(visitor, room)
    ops = [%{"op" => "set", "path" => ["title"], "value" => "Mine"}]
    assert {:error, _} = Participant.transact(visitor, room, ops)
  end

  test "a guest's comments are counted, to the instance's limit", %{room: room, guest: guest} do
    results = for n <- 1..11, do: Comments.start(@instance, room, guest, nil, "Hello #{n}")
    assert Enum.count(results, &match?({:ok, _}, &1)) == 10
    assert {:error, :too_many} = List.last(results)

    # Someone else is not.
    other = Guests.new()
    assert {:ok, _} = Comments.start(@instance, room, other, nil, "Hi")
    person = %{id: "user:ada", name: "Ada"}

    for n <- 1..12,
        do: assert({:ok, _} = Comments.start(@instance, room, person, nil, "Note #{n}"))
  end

  test "a guest asks the room's bot, as the policy lets it, and its requests are counted", %{
    room: room,
    guest: guest
  } do
    assert {:ok, request} =
             Requests.ask(@instance, room, guest, "Where are the docs?", agent: "bot:docs")

    assert request.by.kind == :guest

    assert {:error, :forbidden} =
             Requests.ask(@instance, room, guest, "Hi", agent: "agent:ada-helper")

    for _ <- 2..10,
        do: assert({:ok, _} = Requests.ask(@instance, room, guest, "Again", agent: "bot:docs"))

    assert {:error, :too_many} = Requests.ask(@instance, room, guest, "Again", agent: "bot:docs")
  end
end
