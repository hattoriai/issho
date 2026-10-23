defmodule Issho.AgentsRunTest do
  # An agent's work under Issho: stopped at once, one at a time, its crash
  # said in the room, and the agent found by name in the cluster.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Issho.{Agents, Event, Events, Participant, Transaction, Work}

  @instance IsshoTest.Issho

  setup do
    room = "board:" <> Transaction.id()
    :ok = Events.subscribe(@instance, room)
    claude = %{id: "agent:claude:" <> Transaction.id(), name: "Claude", kind: :agent}
    %{room: room, claude: claude, key: claude.id}
  end

  defp ada, do: %{id: "user:ada", name: "Ada"}

  # A work that starts a task, says so, and waits to be told to end.
  defp working(test) do
    fn participant ->
      :ok = Work.start(participant, "Group the cards", ["Read", "Group"])
      send(test, {:working, self(), participant})

      receive do
        :end -> :ok
      end
    end
  end

  test "a person stops it: its work ends at once, wherever it is", %{
    room: room,
    claude: claude,
    key: key
  } do
    {:ok, work} = Agents.run(@instance, claude, room, working(self()), on_behalf_of: ada())
    ref = Process.monitor(work)
    assert_receive {:working, ^work, participant}

    :ok = Work.interrupt(@instance, room, key, :stop, by: ada())

    assert_receive {:DOWN, ^ref, :process, ^work,
                    {:shutdown, {:stopped, %{"key" => "user:ada"}}}},
                   1_000

    # The agent stays, its task stopped, and may run again.
    assert %{"task" => %{"state" => "stopped"}} = Participant.awareness(participant)
    assert {:ok, again} = Agents.run(@instance, claude, room, fn _ -> :ok end)
    assert is_pid(again)
  end

  test "a pause lets it run, and refuses its changes", %{room: room, claude: claude, key: key} do
    {:ok, work} = Agents.run(@instance, claude, room, working(self()))
    assert_receive {:working, ^work, participant}

    :ok = Work.interrupt(@instance, room, key, :pause, by: ada())
    assert_receive {Issho, :event, %Event{name: "agent.interrupted"}}

    {:ok, _} = Participant.open(participant, room)

    assert {:error, {:interrupted, %{"action" => "pause"}}} =
             Participant.transact(participant, room, [
               %{"op" => "set", "path" => ["title"], "value" => "Mine"}
             ])

    assert Process.alive?(work)
    send(work, :end)
  end

  test "one work at a time", %{room: room, claude: claude} do
    {:ok, work} = Agents.run(@instance, claude, room, working(self()))
    assert_receive {:working, ^work, _participant}
    assert {:error, :running} = Agents.run(@instance, claude, room, fn _ -> :ok end)

    ref = Process.monitor(work)
    send(work, :end)
    assert_receive {:DOWN, ^ref, :process, ^work, :normal}
    assert {:ok, _} = Agents.run(@instance, claude, room, fn _ -> :ok end)
  end

  test "its crash: the task failed, the room hears the kind, the app the reason", %{
    room: room,
    claude: claude,
    key: key
  } do
    test = self()
    handler = "agent-failed-#{key}"

    :telemetry.attach(
      handler,
      [:issho, :agent, :failed],
      fn _name, _measurements, meta, _config -> send(test, {:telemetry, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      capture_log(fn ->
        {:ok, work} =
          Agents.run(@instance, claude, room, fn participant ->
            :ok = Work.start(participant, "Group the cards")
            raise "the model's secret answer"
          end)

        ref = Process.monitor(work)
        assert_receive {:DOWN, ^ref, :process, ^work, {%RuntimeError{}, _stacktrace}}, 1_000

        assert_receive {Issho, :event,
                        %Event{
                          name: "agent.failed",
                          data: %{agent: ^key, title: "Group the cards", reason: "error"} = data
                        }},
                       1_000

        refute inspect(data) =~ "secret"

        assert_receive {:telemetry,
                        %{room: ^room, agent: ^key, reason: {%RuntimeError{message: message}, _}}}

        assert message =~ "secret"
      end)

    assert log =~ "the model's secret answer"

    participant = Agents.participant(@instance, key, room)
    assert %{"task" => %{"state" => "failed"}} = Participant.awareness(participant)
  end

  test "no idle time while its work runs; leaving ends it", %{
    room: room,
    claude: claude,
    key: key
  } do
    {:ok, work} = Agents.run(@instance, claude, room, working(self()), idle: 50)
    ref = Process.monitor(work)
    assert_receive {:working, ^work, _participant}

    Process.sleep(150)
    assert Agents.whereis(@instance, key, room)

    :ok = Agents.leave(@instance, key, room)
    assert_receive {:DOWN, ^ref, :process, ^work, {:shutdown, :left}}, 1_000
  end

  test "its idle time starts when the work ends", %{room: room, claude: claude, key: key} do
    {:ok, work} = Agents.run(@instance, claude, room, fn _ -> :ok end, idle: 50)
    agent = Agents.whereis(@instance, key, room)
    ref = Process.monitor(agent)
    assert_receive {:DOWN, ^ref, :process, ^agent, :normal}, 1_000
    refute Process.alive?(work)
  end

  test "an agent is one in the cluster, by its name", %{room: room, claude: claude, key: key} do
    {:ok, participant} = Agents.join(@instance, claude, room)
    agent = :global.whereis_name({Agents, @instance, key, room})
    assert is_pid(agent)
    assert Agents.whereis(@instance, key, room) == agent
    assert {:ok, ^participant} = Agents.join(@instance, claude, room)
    assert Agents.rooms(@instance, key) == [room]
  end
end
