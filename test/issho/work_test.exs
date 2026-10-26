defmodule Issho.WorkTest do
  # Agents at work, seen and stopped: a task and its steps in the agent's
  # state, and the people's Pause, Resume and Stop.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import IsshoTest.Sync

  alias Issho.{Agents, Event, Events, Participant, Tool, Tools, Transaction, Work}

  @instance IsshoTest.Issho
  @endpoint IsshoTest.Endpoint

  setup do
    room = "board:" <> Transaction.id()
    :ok = Events.subscribe(@instance, room)
    ctx = Tool.Context.new(@instance, claude(), on_behalf_of: ada())
    %{room: room, ctx: ctx, tools: Tools.room()}
  end

  defp ada, do: %{id: "user:ada", name: "Ada"}
  defp ken, do: %{id: "user:ken", name: "Ken"}
  defp claude, do: %{id: "agent:claude", name: "Claude", kind: :agent}

  defp call(tools, ctx, name, args), do: Tools.call(tools, name, args, ctx)

  defp agent(room), do: Agents.participant(@instance, "agent:claude", room)

  test "a task, its steps as they go, and its end, seen by the room", %{
    room: room,
    ctx: ctx,
    tools: tools
  } do
    assert {:ok, "Started."} =
             call(tools, ctx, "start_task", %{
               "room" => room,
               "title" => "Plan the release",
               "steps" => ["Read", "Group", "Write"]
             })

    assert_receive {Issho, :event,
                    %Event{
                      name: "agent.started",
                      data: %{title: "Plan the release", steps: ["Read", "Group", "Write"]}
                    }}

    assert %{"task" => %{"title" => "Plan the release", "state" => "working", "steps" => steps}} =
             Participant.awareness(agent(room))

    assert Enum.map(steps, & &1["state"]) == ["active", "pending", "pending"]

    {:ok, "Noted."} = call(tools, ctx, "progress", %{"room" => room, "step" => "Read"})

    {:ok, "Noted."} =
      call(tools, ctx, "progress", %{
        "room" => room,
        "step" => "Group",
        "state" => "skipped",
        "add" => ["Check"],
        "note" => "Few cards"
      })

    %{"task" => %{"steps" => steps, "note" => "Few cards"}} = Participant.awareness(agent(room))

    assert Enum.map(steps, &{&1["label"], &1["state"]}) == [
             {"Read", "done"},
             {"Group", "skipped"},
             {"Write", "active"},
             {"Check", "pending"}
           ]

    {:ok, "Finished."} = call(tools, ctx, "finish_task", %{"room" => room, "summary" => "Done."})

    assert_receive {Issho, :event,
                    %Event{
                      name: "agent.finished",
                      data: %{title: "Plan the release", summary: "Done."}
                    }}

    assert %{"task" => nil} = Participant.awareness(agent(room))

    assert {:error, "You have no task in this room: start_task first."} =
             call(tools, ctx, "progress", %{"room" => room, "step" => "Read"})
  end

  test "the person it acts for pauses it: it changes nothing more, but reads, until resumed", %{
    room: room,
    ctx: ctx,
    tools: tools
  } do
    {:ok, _} = call(tools, ctx, "start_task", %{"room" => room, "title" => "Rename"})
    {:ok, ada} = Issho.join_as(@instance, ada(), room)
    {:present, %{session: session}} = :sys.get_state(ada)

    :ok = Issho.Session.interrupt(session, "agent:claude", :pause)

    assert_receive {Issho, :event,
                    %Event{
                      name: "agent.interrupted",
                      by: %{key: "user:ada"},
                      data: %{agent: "agent:claude", action: "pause"}
                    }}

    settle(agent(room))

    assert %{"action" => "pause", "by" => %{"name" => "Ada"}} =
             Participant.interrupted(agent(room))

    assert %{"task" => %{"state" => "paused", "by" => %{"name" => "Ada"}}} =
             Participant.awareness(agent(room))

    ops = [%{"op" => "set", "path" => ["title"], "value" => "New"}]

    assert {:error, "Ada paused you." <> _} =
             call(tools, ctx, "change_document", %{"room" => room, "ops" => ops})

    assert {:ok, _} = call(tools, ctx, "read_document", %{"room" => room})
    assert {:error, {:interrupted, _}} = Participant.transact(agent(room), room, ops)

    # A paused agent starts no other task to go on.
    assert {:error, "Ada paused you." <> _} =
             call(tools, ctx, "start_task", %{"room" => room, "title" => "Something else"})

    :ok = Issho.Session.interrupt(session, "agent:claude", :resume)
    assert_receive {Issho, :event, %Event{name: "agent.resumed", data: %{agent: "agent:claude"}}}
    settle(agent(room))

    assert %{"task" => %{"state" => "working"}} = Participant.awareness(agent(room))

    assert {:ok, %{"revision" => _}} =
             call(tools, ctx, "change_document", %{"room" => room, "ops" => ops})
  end

  describe "beyond Issho's documents" do
    setup %{room: room, ctx: ctx, tools: tools} do
      {:ok, _} = call(tools, ctx, "start_task", %{"room" => room, "title" => "Choose"})
      {:ok, ada} = Issho.join_as(@instance, ada(), room)
      {:present, %{session: session}} = :sys.get_state(ada)
      %{session: session, place: %{"doc" => room, "at" => %{"path" => ["title"]}}}
    end

    defp pause(session, room) do
      :ok = Issho.Session.interrupt(session, "agent:claude", :pause)
      assert_receive {Issho, :event, %Event{name: "agent.interrupted"}}
      settle(agent(room))
    end

    test "paused, it goes nowhere new and holds no lock; it may still clear, say its task, leave",
         %{
           room: room,
           session: session,
           place: place
         } do
      agent = agent(room)
      :ok = Participant.place(agent, place)
      :ok = Participant.lock(agent, [place])
      pause(session, room)

      # Its locks are released, so the people it would block go on; its
      # place stays, where it stopped.
      assert %{"locks" => [], "place" => ^place} = Participant.awareness(agent)

      other = %{"doc" => room, "at" => %{"path" => ["body"]}}
      assert {:error, {:interrupted, %{"action" => "pause"}}} = Participant.place(agent, other)
      assert {:error, {:interrupted, _}} = Participant.lock(agent, [other])
      assert {:error, {:interrupted, _}} = Issho.Motion.go(agent, other)

      assert {:error, {:interrupted, _}} =
               Participant.aware_block(agent, room, %{"cursor" => [1, 2]})

      assert :ok = Participant.aware(agent, %{"status" => "Waiting"})
      assert :ok = Participant.aware_block(agent, room, %{"cursor" => nil})
      assert :ok = Work.progress(agent, 0, :done)
      assert :ok = Participant.place(agent, nil)

      :ok = Issho.Session.interrupt(session, "agent:claude", :resume)
      assert_receive {Issho, :event, %Event{name: "agent.resumed"}}
      settle(agent)
      assert :ok = Participant.place(agent, other)
    end

    test "guard/2: the app's own change runs unless it is paused or stopped", %{
      room: room,
      session: session
    } do
      agent = agent(room)
      assert {:ok, :saved} = Work.guard(agent, fn -> {:ok, :saved} end)

      pause(session, room)
      test = self()

      assert {:error, {:interrupted, %{"action" => "pause", "by" => %{"name" => "Ada"}}}} =
               Work.guard(agent, fn -> send(test, :written) end)

      refute_received :written
    end

    test "Tool.Context.guard/3: for a tool whose arguments do not name the room", %{
      room: room,
      ctx: ctx,
      session: session
    } do
      assert :ran = Tool.Context.guard(ctx, room, fn -> :ran end)
      # Not in that room: not paused there.
      assert :ran = Tool.Context.guard(ctx, "board:elsewhere", fn -> :ran end)

      pause(session, room)
      assert {:error, {:interrupted, by}} = Tool.Context.guard(ctx, room, fn -> :ran end)
      assert {:error, "Ada paused you." <> _} = Tool.Context.error({:interrupted, by})
    end
  end

  test "stopped, it finishes, and may begin another task", %{room: room, ctx: ctx, tools: tools} do
    {:ok, _} = call(tools, ctx, "start_task", %{"room" => room, "title" => "Rename"})
    :ok = Work.interrupt(@instance, room, "agent:claude", :stop, by: ada())
    assert_receive {Issho, :event, %Event{name: "agent.interrupted", data: %{action: "stop"}}}
    settle(agent(room))

    ops = [%{"op" => "set", "path" => ["title"], "value" => "New"}]

    assert {:error, "Ada stopped you. Stop this work in the room: call finish_task" <> _} =
             call(tools, ctx, "change_document", %{"room" => room, "ops" => ops})

    assert {:ok, "Finished."} =
             call(tools, ctx, "finish_task", %{"room" => room, "summary" => "Stopped."})

    assert {:ok, %{"revision" => _}} =
             call(tools, ctx, "change_document", %{"room" => room, "ops" => ops})
  end

  test "someone else may not, unless the policy allows :interrupt", %{
    room: room,
    ctx: ctx,
    tools: tools
  } do
    {:ok, _} = call(tools, ctx, "start_task", %{"room" => room, "title" => "Rename"})
    {:ok, ken} = Issho.join_as(@instance, ken(), room)
    {:present, %{session: session}} = :sys.get_state(ken)

    IsshoTest.Policy.deny_action(:interrupt)
    on_exit(fn -> IsshoTest.Policy.allow_action(:interrupt) end)
    assert {:error, :forbidden} = Issho.Session.interrupt(session, "agent:claude", :stop)

    IsshoTest.Policy.allow_action(:interrupt)
    assert :ok = Issho.Session.interrupt(session, "agent:claude", :stop)
  end

  test "from a LiveView", %{room: room, ctx: ctx, tools: tools} do
    {:ok, _} = call(tools, ctx, "start_task", %{"room" => room, "title" => "Rename"})

    {:ok, view, _} =
      live_isolated(build_conn(), IsshoTest.BoardLive,
        session: %{"user" => "user:ada", "room" => room}
      )

    # The LiveView's person is Ada, by key: the one the agent acts for.
    render_click(view, "interrupt", %{"agent" => "agent:claude", "action" => "pause"})
    assert_receive {Issho, :event, %Event{name: "agent.interrupted", data: %{action: "pause"}}}

    # The LiveViews of the room take the pause as theirs, not the app's.
    settle(view.pid)
    assert render(view) =~ "messages"
  end
end
