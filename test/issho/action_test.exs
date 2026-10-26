defmodule Issho.ActionTest do
  # One action for a person's button and an agent's tool: the same policy,
  # the same invariant, done once for a retry, and never "done" when it
  # was refused, stale or paused.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import IsshoTest.Sync

  alias Issho.{Action, Agents, Event, Events, Tool, Tools, Transaction}
  alias Issho.Action.Receipt
  alias IsshoTest.CheckItem

  @instance IsshoTest.Issho
  @endpoint IsshoTest.Endpoint

  setup do
    room = "board:" <> Transaction.id()
    :ok = Events.subscribe(@instance, room)
    ctx = Tool.Context.new(@instance, claude(), on_behalf_of: ada())
    on_exit(fn -> Agents.leave(@instance, "agent:claude", room) end)
    %{room: room, ctx: ctx, tools: [CheckItem | Tools.room()]}
  end

  defp ada, do: %{id: "user:ada", name: "Ada"}
  defp claude, do: %{id: "agent:claude", name: "Claude", kind: :agent}

  defp check(tools, ctx, args), do: Tools.call(tools, "check_item", args, ctx)

  defp board(room) do
    {:ok, view, _} =
      live_isolated(build_conn(), IsshoTest.BoardLive,
        session: %{"user" => "user:ada", "room" => room}
      )

    view
  end

  defp messages(view) do
    settle(view.pid)
    view |> element("#messages") |> render()
  end

  test "a person's button and an agent's tool run the same action, each as itself", %{
    room: room,
    ctx: ctx,
    tools: tools
  } do
    view = board(room)
    render_click(view, "check", %{"item" => "Draft", "done" => "true"})
    assert messages(view) =~ "acted:ok"

    assert_receive {Issho, :event,
                    %Event{
                      name: "action.done",
                      by: %{key: "user:ada"},
                      data: %{action: "check_item", item: "Draft", done: true}
                    }}

    assert %{done: true, by: "user:ada", runs: 1} = CheckItem.entry(room, "Draft")

    assert {:ok, "Unchecked Draft."} =
             check(tools, ctx, %{"list" => room, "item" => "Draft", "done" => false})

    # The agent is in the room, seen there, and the room hears it did it,
    # for Ada.
    assert is_pid(Agents.participant(@instance, "agent:claude", room))

    assert_receive {Issho, :event,
                    %Event{
                      name: "action.done",
                      by: %{key: "agent:claude", on_behalf_of: %{key: "user:ada"}},
                      data: %{item: "Draft", done: false}
                    }}

    assert %{done: false, by: "agent:claude", runs: 2} = CheckItem.entry(room, "Draft")
  end

  test "the same policy and the same invariant refuse both", %{
    room: room,
    ctx: ctx,
    tools: tools
  } do
    view = board(room)

    render_click(view, "check", %{"item" => "archived:Old", "done" => "true"})
    assert messages(view) =~ "acted:That item is archived."

    assert {:error, "That item is archived."} =
             check(tools, ctx, %{"list" => room, "item" => "archived:Old", "done" => true})

    readonly = "readonly:" <> Transaction.id()

    assert {:error, :forbidden} =
             Action.invoke(@instance, CheckItem, %{list: readonly, item: "A", done: true}, ada())

    assert {:error, "The room's policy does not allow this."} =
             check(tools, ctx, %{"list" => readonly, "item" => "A", "done" => true})

    assert Action.allowed(@instance, CheckItem, %{list: room, item: "A", done: true}, ada()) ==
             :ok

    assert {:error, "That item is archived."} =
             Action.allowed(
               @instance,
               CheckItem,
               %{list: room, item: "archived:A", done: true},
               ada()
             )

    assert {:error, {:invalid, "done is required."}} =
             Action.invoke(@instance, CheckItem, %{list: room, item: "A"}, ada())

    assert CheckItem.entry(room, "archived:Old") == nil
    assert CheckItem.entry(readonly, "A") == nil
    refute_received {Issho, :event, %Event{name: "action.done"}}
  end

  test "a retry is done once; its id with other arguments is refused", %{
    room: room,
    ctx: ctx,
    tools: tools
  } do
    args = %{"list" => room, "item" => "Ship", "done" => true, "invocation_id" => "ship-1"}

    assert {:ok, "Checked Ship."} = check(tools, ctx, args)

    assert {:ok, "Checked Ship. (Done before, with this invocation_id: not done again.)"} =
             check(tools, ctx, args)

    assert %{runs: 1} = CheckItem.entry(room, "Ship")

    assert {:error, "That invocation_id was used for another change: give a new one" <> _} =
             check(tools, ctx, %{args | "done" => false})

    # The same id is not someone else's either.
    assert {:error, :id_reused} =
             Action.invoke(@instance, CheckItem, args, ada(), id: "ship-1")

    # From the LiveView, with its own id.
    view = board(room)
    render_click(view, "check", %{"item" => "Test", "done" => "true", "id" => "test-1"})
    render_click(view, "check", %{"item" => "Test", "done" => "true", "id" => "test-1"})
    assert messages(view) =~ "acted:replayed"
    assert %{runs: 1} = CheckItem.entry(room, "Test")
  end

  test "one still running is in progress; one that failed may run again", %{room: room} do
    :persistent_term.put({CheckItem, :waiter}, self())
    on_exit(fn -> :persistent_term.erase({CheckItem, :waiter}) end)
    args = %{list: room, item: "slow", done: true}

    task = Task.async(fn -> Action.invoke(@instance, CheckItem, args, ada(), id: "slow-1") end)
    assert_receive {:running, runner}

    assert {:error, :in_progress} = Action.invoke(@instance, CheckItem, args, ada(), id: "slow-1")

    send(runner, :go)
    assert {:ok, %Receipt{id: "slow-1", action: "check_item", replayed: false}} = Task.await(task)

    broken = %{list: room, item: "broken", done: true}

    assert {:error, "That item is broken."} =
             Action.invoke(@instance, CheckItem, broken, ada(), id: "broken-1")

    assert {:error, "That item is broken."} =
             Action.invoke(@instance, CheckItem, broken, ada(), id: "broken-1")
  end

  test "a paused agent changes nothing, and is told; resumed, the same id runs", %{
    room: room,
    ctx: ctx,
    tools: tools
  } do
    args = %{"list" => room, "item" => "Plan", "done" => true, "invocation_id" => "plan-1"}
    {:ok, _} = Tools.call(tools, "start_task", %{"room" => room, "title" => "Plan"}, ctx)
    {:ok, ada} = Issho.join_as(@instance, ada(), room)
    {:present, %{session: session}} = :sys.get_state(ada)
    agent = Agents.participant(@instance, "agent:claude", room)

    :ok = Issho.Session.interrupt(session, "agent:claude", :pause)
    assert_receive {Issho, :event, %Event{name: "agent.interrupted"}}
    settle(agent)

    assert {:error, "Ada paused you" <> _} = check(tools, ctx, args)
    assert CheckItem.entry(room, "Plan") == nil
    refute_received {Issho, :event, %Event{name: "action.done"}}

    # Your own code, as the agent, is paused there too.
    assert {:error, {:interrupted, %{"action" => "pause"}}} =
             Action.invoke(@instance, CheckItem, args, claude(), on_behalf_of: ada())

    :ok = Issho.Session.interrupt(session, "agent:claude", :resume)
    assert_receive {Issho, :event, %Event{name: "agent.resumed"}}
    settle(agent)

    assert {:ok, "Checked Plan."} = check(tools, ctx, args)
    assert %{runs: 1} = CheckItem.entry(room, "Plan")
  end

  test "its tool says what it takes, and how to retry", %{tools: tools} do
    [schema] = tools |> Enum.take(1) |> Tools.schemas()

    assert %{
             "name" => "check_item",
             "input_schema" => %{
               "properties" => %{"invocation_id" => %{"type" => "string"}, "list" => _},
               "required" => ["list", "item", "done"]
             }
           } = schema
  end
end
