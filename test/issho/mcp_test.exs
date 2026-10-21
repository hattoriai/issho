defmodule Issho.MCPTest do
  use ExUnit.Case, async: false

  import Sake.Test

  alias Issho.{Agents, Participant, Transaction}

  @instance IsshoTest.Issho
  @ada %{id: "user:ada", name: "Ada"}

  setup do
    Application.put_env(:issho, Issho.MCP, instance: @instance)
    on_exit(fn -> Application.delete_env(:issho, Issho.MCP) end)
    %{room: "board:" <> Transaction.id()}
  end

  defp claude(scope \\ @ada),
    do:
      connect(Issho.MCP,
        scope: scope,
        client_info: %{"name" => "claude-code", "title" => "Claude Code"}
      )

  # Ken, a person in the room, in this test's process.
  defp ken(room) do
    {:ok, ken} = Issho.join_as(@instance, %{id: "user:ken", name: "Ken"}, room)
    {:ok, _} = Participant.open(ken, room)
    ken
  end

  test "an agent joins a room for the person who connected it, and stays between calls",
       %{room: room} do
    _ken = ken(room)
    client = claude()

    assert {:ok, %{structured: joined}} = call_tool(client, "join_room", %{"room" => room})
    assert joined["you"] == "agent:claude-code:user:ada"

    assert %{"name" => "Claude Code", "kind" => "agent", "you" => true, "on_behalf_of" => "Ada"} =
             Enum.find(joined["people"], & &1["you"])

    assert Enum.any?(joined["people"], &(&1["key"] == "user:ken"))

    participant = Agents.participant(@instance, joined["you"], room)
    assert is_pid(participant)

    # Another call is the same agent.
    assert {:ok, _} = call_tool(client, "look_around", %{"room" => room})
    assert Agents.participant(@instance, joined["you"], room) == participant
    assert room in Agents.rooms(@instance, joined["you"])
  end

  test "an agent reads, points and changes, and the people in the room see it", %{room: room} do
    ken = ken(room)
    client = claude()

    assert {:ok, %{structured: %{"state" => %{"title" => "Untitled"}, "revision" => 0}}} =
             call_tool(client, "read_document", %{"room" => room})

    ops = [%{"op" => "set", "path" => ["title"], "value" => "Plan"}]

    assert {:ok, %{structured: %{"revision" => 1}}} =
             call_tool(client, "change_document", %{"room" => room, "ops" => ops})

    assert_receive {Participant, ^ken, "tx",
                    %{"event" => %{"author" => "agent:claude-code:user:ada"}}}

    assert {:ok, _} =
             call_tool(client, "point", %{"room" => room, "at" => %{"path" => ["title"]}})

    assert {:ok, _} = call_tool(client, "set_status", %{"room" => room, "status" => "Renaming"})

    assert_receive {Participant, ^ken, "aware", %{"states" => states}} when map_size(states) > 0,
                   1_000

    assert Enum.any?(Map.values(states), fn
             %{"key" => "agent:claude-code:user:ada", "state" => state} ->
               state["status"] == "Renaming" and state["place"]["at"] == %{"path" => ["title"]}

             _ ->
               false
           end) or
             eventually_sees(ken, "Renaming")
  end

  test "the room's policy decides for an agent as for anyone", %{room: room} do
    client = claude()

    assert {:ok, %{is_error: true, text: text}} =
             call_tool(client, "change_document", %{
               "room" => "readonly:" <> room,
               "ops" => [%{"op" => "set", "path" => ["title"], "value" => "x"}]
             })

    assert text =~ "policy"
  end

  test "an agent leaves when told, and after a quiet while", %{room: room} do
    client = claude()
    {:ok, %{structured: %{"you" => key}}} = call_tool(client, "join_room", %{"room" => room})
    assert {:ok, _} = call_tool(client, "leave_room", %{"room" => room})
    assert Agents.participant(@instance, key, room) == nil

    {:ok, participant} =
      Agents.join(@instance, %{id: "agent:quiet", kind: :agent}, room, idle: 20)

    ref = Process.monitor(participant)
    assert_receive {:DOWN, ^ref, _, _, _}, 1_000
  end

  test "without a person, the agent is the client's own" do
    client = claude(nil)
    room = "board:" <> Transaction.id()

    assert {:ok, %{structured: %{"you" => "agent:claude-code"}}} =
             call_tool(client, "join_room", %{"room" => room})
  end

  # Awareness frames carry what changed since the last one: wait for the frame with the status.
  defp eventually_sees(ken, status) do
    receive do
      {Participant, ^ken, "aware", %{"states" => states}} ->
        Enum.any?(Map.values(states), &(get_in(&1, ["state", "status"]) == status)) or
          eventually_sees(ken, status)
    after
      1_000 -> false
    end
  end
end
