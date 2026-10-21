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

  defmodule Mapping do
    @moduledoc false
    # Two endpoints of one app: people's assistants, and the app's own bot.
    def assistant(%Sake.Context{scope: %{id: id} = person}),
      do: {%{id: "assistant:#{id}", name: "Assistant", kind: :agent}, on_behalf_of: person}

    def bot(_ctx), do: {%{id: "bot:app", name: "App bot", kind: :service}, []}
  end

  defmodule People do
    @moduledoc false
    use Plug.Builder
    plug :person
    plug Issho.MCP.Setup, agent: {Issho.MCPTest.Mapping, :assistant}

    plug Sake.Plug,
      server: Issho.MCP,
      scope: &__MODULE__.scope/1,
      secret: String.duplicate("s", 64)

    def person(conn, _opts), do: Plug.Conn.assign(conn, :person, %{id: "user:ada", name: "Ada"})
    def scope(conn), do: conn.assigns.person
  end

  defmodule Bot do
    @moduledoc false
    use Plug.Builder
    plug Issho.MCP.Setup, agent: {Issho.MCPTest.Mapping, :bot}
    plug Sake.Plug, server: Issho.MCP, secret: String.duplicate("s", 64)
  end

  defmodule Endpoints do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    forward "/people/mcp", to: Issho.MCPTest.People
    forward "/bot/mcp", to: Issho.MCPTest.Bot
  end

  test "an app has a person's assistant and its own bot at once, each on its endpoint",
       %{room: room} do
    ken = ken(room)
    assistant = connect(Issho.MCP, plug: Endpoints, path: "/people/mcp")
    bot = connect(Issho.MCP, plug: Endpoints, path: "/bot/mcp")

    assert {:ok, %{structured: %{"you" => "assistant:user:ada"}}} =
             call_tool(assistant, "join_room", %{"room" => room})

    assert {:ok, %{structured: %{"you" => "bot:app", "people" => people}}} =
             call_tool(bot, "join_room", %{"room" => room})

    assert %{"kind" => "agent", "on_behalf_of" => "Ada"} =
             Enum.find(people, &(&1["key"] == "assistant:user:ada"))

    assert %{"kind" => "service", "on_behalf_of" => nil, "you" => true} =
             Enum.find(people, &(&1["key"] == "bot:app"))

    people = Participant.people(ken)
    assert Map.has_key?(people, "assistant:user:ada") and Map.has_key?(people, "bot:app")
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
