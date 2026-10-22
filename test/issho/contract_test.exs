defmodule Issho.ContractTest do
  # What every component shares with Issho: one way to join, the author of
  # each change, a component's own keys in a person's state, and the
  # room's events.
  use ExUnit.Case, async: false

  alias Issho.{
    Authority,
    Awareness,
    Documents,
    Event,
    Events,
    Identity,
    Join,
    Participant,
    Transaction
  }

  @instance IsshoTest.Issho

  describe "Issho.Join" do
    test "the same keys in every component, the room from the document" do
      join = Join.new!(instance: @instance, document: "page:1/body", can: :read, people: false)

      assert %Join{room: "page:1", can: :read, people: false, follow: true, claims: %{}} = join
      assert Join.grant_opts(join) == [can: :read, claims: %{}]
    end

    test "a component's own keys, and no other" do
      assert %Join{extra: %{undo: :page}} =
               Join.new!([instance: @instance, document: "a:1", undo: :page], [:undo])

      assert_raise ArgumentError, ~r/not \[:undo\]/, fn ->
        Join.new!(instance: @instance, document: "a:1", undo: :page)
      end

      assert_raise ArgumentError, ~r/needs :document/, fn -> Join.new!(instance: @instance) end

      assert_raise ArgumentError, ~r/:can is :write or :read/, fn ->
        Join.new!(instance: @instance, document: "a:1", can: :admin)
      end
    end
  end

  describe "the author of a change" do
    test "the hook gets who made it, as an identity, and the room an event" do
      test = self()
      room = "canvas:" <> Transaction.id()
      hook = fn _ops, context -> send(test, {:by, context.author, context.by}) && :ok end
      spec = %{engine: Issho.Engine.Map, initial: %{}, store: :none, on_transaction: hook}
      {:ok, pid} = Documents.open(@instance, room, nil, spec: spec)
      :ok = Events.subscribe(@instance, room)

      agent =
        Identity.new(%{id: "agent:claude", name: "Claude", kind: :agent},
          on_behalf_of: %{id: "user:ada", name: "Ada"}
        )

      {:ok, snapshot} = Authority.snapshot(pid)

      tx = %{
        "id" => Transaction.id(),
        "epoch" => snapshot["epoch"],
        "base_revision" => 0,
        "ops" => [%{"op" => "set", "path" => ["title"], "value" => "Plan"}]
      }

      assert {:ok, %{"revision" => 1}} = Authority.commit(pid, tx, agent)

      assert_receive {:by, "agent:claude",
                      %Identity{
                        kind: :agent,
                        name: "Claude",
                        on_behalf_of: %Identity{key: "user:ada"}
                      }}

      assert_receive {Issho, :event,
                      %Event{
                        name: "document.changed",
                        room: ^room,
                        document: ^room,
                        data: %{revision: 1},
                        by: %Identity{key: "agent:claude"}
                      }}
    end

    test "your server's own change is a service's, or an actor's" do
      test = self()
      room = "canvas:" <> Transaction.id()
      hook = fn _ops, context -> send(test, {:by, context.by}) && :ok end
      spec = %{engine: Issho.Engine.Map, initial: %{}, store: :none, on_transaction: hook}
      {:ok, _pid} = Documents.open(@instance, room, nil, spec: spec)

      {:ok, _} =
        Issho.transact(@instance, room, [%{"op" => "set", "path" => ["a"], "value" => 1}])

      assert_receive {:by, %Identity{key: "server", kind: :service}}

      {:ok, _} =
        Issho.transact(@instance, room, [%{"op" => "set", "path" => ["a"], "value" => 2}],
          author: %{id: "user:ken", name: "Ken"}
        )

      assert_receive {:by, %Identity{key: "user:ken", name: "Ken", kind: :human}}
    end
  end

  describe "a component's own keys in a person's state" do
    test "under its document, apart from Issho's and from other components'" do
      state =
        %{"place" => %{"doc" => "board:1", "at" => %{}}}
        |> Awareness.put_block("board:1", %{"cursor" => [1, 2], "viewport" => [0, 0, 10, 10]})
        |> Awareness.put_block("board:1/rows", %{"view" => "mine"})

      assert state["place"] == %{"doc" => "board:1", "at" => %{}}

      assert Awareness.block(state, "board:1") == %{
               "cursor" => [1, 2],
               "viewport" => [0, 0, 10, 10]
             }

      assert Awareness.block(state, "board:1/rows") == %{"view" => "mine"}
      assert Awareness.block(state, "nothing") == %{}

      state = state |> Awareness.put_block("board:1", %{"cursor" => nil, "viewport" => nil})
      assert Awareness.block(state, "board:1") == %{}
      refute Map.has_key?(state["blocks"], "board:1")

      assert Awareness.put_block(state, "board:1/rows", %{"view" => nil}) == %{
               "place" => state["place"]
             }
    end

    test "an agent sets its own, and keeps Issho's" do
      room = "board:" <> Transaction.id()

      {:ok, agent} =
        Issho.join_as(@instance, %{id: "agent:one", name: "Agent", kind: :agent}, room)

      :ok = Participant.aware(agent, %{"status" => "Drawing"})
      :ok = Participant.aware_block(agent, room, %{"cursor" => [3, 4]})

      assert %{"status" => "Drawing", "blocks" => %{^room => %{"cursor" => [3, 4]}}} =
               Participant.awareness(agent)
    end
  end

  test "an app's own event reaches the room's subscribers" do
    room = "retro:" <> Transaction.id()
    :ok = Events.subscribe(@instance, room)

    :ok =
      Events.emit(@instance, room, "retro.voted",
        by: %{id: "user:ada", name: "Ada"},
        data: %{card: "c1"}
      )

    assert_receive {Issho, :event,
                    %Event{
                      name: "retro.voted",
                      room: ^room,
                      data: %{card: "c1"},
                      by: %Identity{key: "user:ada"}
                    }}
  end
end
