defmodule Issho.EventsTest do
  # A room's events: who comes and goes, what someone selects, and those
  # who hear them (telemetry, a LiveView's components, participants and
  # the agents that wait for them).
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import IsshoTest.Sync

  alias Issho.{Agents, Event, Events, Identity, Participant, Tool, Tools, Transaction}

  doctest Issho.Events

  @instance IsshoTest.Issho
  @endpoint IsshoTest.Endpoint

  setup do
    room = "board:" <> Transaction.id()
    :ok = Events.subscribe(@instance, room)
    %{room: room}
  end

  defp ada, do: %{id: "user:ada", name: "Ada"}
  defp claude, do: %{id: "agent:claude", name: "Claude", kind: :agent}

  describe "people" do
    test "an actor joins once and leaves once, whatever its tabs", %{room: room} do
      {:ok, first} = Issho.join_as(@instance, ada(), room)

      assert_receive {Issho, :event,
                      %Event{
                        name: "person.joined",
                        room: ^room,
                        by: %Identity{key: "user:ada", name: "Ada"},
                        data: %{can: "write"}
                      }}

      {:ok, second} = Issho.join_as(@instance, ada(), room, can: :read)
      :ok = Participant.leave(first)
      refute_receive {Issho, :event, %Event{name: "person." <> _}}, 100

      :ok = Participant.leave(second)

      assert_receive {Issho, :event,
                      %Event{name: "person.left", room: ^room, by: %Identity{key: "user:ada"}}}
    end

    test "an agent and whom it acts for", %{room: room} do
      {:ok, _agent} = Issho.join_as(@instance, claude(), room, on_behalf_of: ada())

      assert_receive {Issho, :event,
                      %Event{
                        name: "person.joined",
                        by: %Identity{
                          key: "agent:claude",
                          kind: :agent,
                          on_behalf_of: %Identity{key: "user:ada"}
                        }
                      }}
    end
  end

  describe "selection.changed" do
    test "when a session's place changes, not when it stays", %{room: room} do
      {:ok, agent} = Issho.join_as(@instance, claude(), room)
      place = %{"doc" => room, "at" => %{"path" => ["title"]}}

      :ok = Participant.place(agent, place)

      assert_receive {Issho, :event,
                      %Event{
                        name: "selection.changed",
                        document: ^room,
                        by: %Identity{key: "agent:claude"},
                        data: %{place: ^place, session: session}
                      }}

      assert is_binary(session)

      :ok = Participant.aware(agent, %{"status" => "Reading"})
      refute_receive {Issho, :event, %Event{name: "selection.changed"}}, 50

      :ok = Participant.place(agent, nil)

      assert_receive {Issho, :event,
                      %Event{name: "selection.changed", document: nil, data: %{place: nil}}}
    end
  end

  test "every event is a telemetry event", %{room: room} do
    test = self()
    id = {__MODULE__, room}

    :telemetry.attach(
      id,
      [:issho, :event],
      fn _name, measurements, metadata, _config ->
        send(test, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    :ok = Events.emit(@instance, room, "retro.voted", data: %{card: "c1"})

    assert_receive {:telemetry, %{system_time: _},
                    %{event: %Event{name: "retro.voted", room: ^room}, pubsub: IsshoTest.PubSub}}
  end

  test "an event as JSON, for a model or a browser", %{room: room} do
    event = %Event{
      name: "retro.voted",
      room: room,
      document: room <> "/cards",
      by: Identity.new(claude(), on_behalf_of: ada(), claims: %{"secret" => 1}),
      data: %{card: "c1", votes: [1, 2], at: ~U[2026-10-23 10:00:00Z], ref: {:a, 1}, ok: true},
      at: ~U[2026-10-23 10:00:01Z]
    }

    assert Event.to_map(event) == %{
             "name" => "retro.voted",
             "room" => room,
             "document" => room <> "/cards",
             "by" => %{
               "key" => "agent:claude",
               "name" => "Claude",
               "kind" => "agent",
               "on_behalf_of" => %{"key" => "user:ada", "name" => "Ada", "kind" => "human"}
             },
             "data" => %{
               "card" => "c1",
               "votes" => [1, 2],
               "at" => "2026-10-23T10:00:00Z",
               "ref" => "{:a, 1}",
               "ok" => true
             },
             "at" => "2026-10-23T10:00:01Z"
           }

    _ = JSON.encode!(Event.to_map(event))
  end

  describe "participants" do
    test "hear the room's events with events: true, but their own", %{room: room} do
      {:ok, agent} = Issho.join_as(@instance, claude(), room, events: true)
      {:ok, _} = Participant.open(agent, room)

      :ok = Events.emit(@instance, room, "retro.voted", by: ada())
      assert_receive {Participant, ^agent, "event", %Event{name: "retro.voted"}}

      {:ok, _} =
        Participant.transact(agent, room, [%{"op" => "set", "path" => ["a"], "value" => 1}])

      assert_receive {Issho, :event, %Event{name: "document.changed"}}
      refute_receive {Participant, ^agent, "event", %Event{name: "document.changed"}}, 50
    end

    test "hear none without it", %{room: room} do
      {:ok, agent} = Issho.join_as(@instance, claude(), room)
      :ok = Events.emit(@instance, room, "retro.voted", by: ada())
      refute_receive {Participant, ^agent, "event", _}, 50
    end
  end

  describe "agents wait for events" do
    test "those since they last asked, of the names they want, or the next", %{room: room} do
      {:ok, _} = Agents.join(@instance, claude(), room)
      key = "agent:claude"

      :ok = Events.emit(@instance, room, "retro.voted", by: ada(), data: %{card: "c1"})
      :ok = Events.emit(@instance, room, "comment.created", by: ada())
      settle_agent(key, room)

      assert {:ok, [%Event{name: "comment.created"}]} =
               Agents.wait(@instance, key, room, ["comment.*"], 0)

      assert {:ok, [%Event{name: "retro.voted", data: %{card: "c1"}}]} =
               Agents.wait(@instance, key, room, :all, 0)

      assert {:ok, []} = Agents.wait(@instance, key, room, :all, 20)

      waiting = Task.async(fn -> Agents.wait(@instance, key, room, ["retro.voted"], 2_000) end)
      Process.sleep(20)
      :ok = Events.emit(@instance, room, "comment.created", by: ada())
      :ok = Events.emit(@instance, room, "retro.voted", by: ada(), data: %{card: "c2"})

      assert {:ok, [%Event{name: "retro.voted", data: %{card: "c2"}}]} = Task.await(waiting)
      assert {:ok, [%Event{name: "comment.created"}]} = Agents.wait(@instance, key, room, :all, 0)
    end

    test "an agent not in the room waits for nothing", %{room: room} do
      assert {:error, :not_there} = Agents.wait(@instance, "agent:nobody", room, :all, 0)
    end

    test "the wait_for_events tool", %{room: room} do
      ctx = Tool.Context.new(@instance, claude(), on_behalf_of: ada())
      {:ok, _} = Tools.call(Tools.room(), "join_room", %{"room" => room}, ctx)

      :ok = Events.emit(@instance, room, "retro.voted", by: ada(), data: %{card: "c1"})
      settle_agent("agent:claude", room)

      assert {:ok,
              %{"events" => [%{"name" => "retro.voted", "data" => %{"card" => "c1"}} = event]}} =
               Tools.call(
                 Tools.room(),
                 "wait_for_events",
                 %{"room" => room, "names" => ["retro.*"], "seconds" => 0},
                 ctx
               )

      assert %{"by" => %{"name" => "Ada"}} = event

      assert {:ok, %{"events" => []}} =
               Tools.call(Tools.room(), "wait_for_events", %{"room" => room, "seconds" => 0}, ctx)
    end
  end

  test "a LiveView hears the events it asks for", %{room: room} do
    {:ok, view, _} =
      live_isolated(build_conn(), IsshoTest.BoardLive,
        session: %{"user" => "user:ada", "room" => room}
      )

    render_click(view, "listen", %{"names" => ["retro.*"]})

    :ok = Events.emit(@instance, room, "retro.voted", by: claude())
    :ok = Events.emit(@instance, room, "comment.created", by: claude())
    assert_receive {Issho, :event, %Event{name: "comment.created"}}
    settle(view.pid)

    html = render(view)
    assert html =~ "event:retro.voted"
    refute html =~ "event:comment.created"
  end

  # The agent's process has handled the events already sent to it.
  defp settle_agent(key, room) do
    participant = Agents.participant(@instance, key, room)
    settle(participant)
    [{agent, _}] = Registry.lookup(Issho.Config.child_name(@instance, AgentRegistry), {key, room})
    settle(agent)
  end
end
