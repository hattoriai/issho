defmodule Issho.ActionComponentTest do
  # A component's action: its change is a transaction of its document, as
  # whoever runs it; an agent's is seen on its way (its gesture), paused
  # on its way changes nothing, and an agent finds what it may do.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import IsshoTest.Sync

  alias Issho.{Action, Agents, Event, Events, Participant, Tool, Tools, Transaction}

  @instance IsshoTest.Issho
  @endpoint IsshoTest.Endpoint

  setup do
    room = "board:" <> Transaction.id()
    :ok = Events.subscribe(@instance, room)
    ctx = Tool.Context.new(@instance, claude(), on_behalf_of: ada())
    on_exit(fn -> Agents.leave(@instance, "agent:claude", room) end)
    %{room: room, ctx: ctx, tools: [IsshoTest.Retitle, IsshoTest.CheckItem | Tools.room()]}
  end

  defp ada, do: %{id: "user:ada", name: "Ada"}
  defp claude, do: %{id: "agent:claude", name: "Claude", kind: :agent}

  defp title(room) do
    {:ok, agent} = Agents.join(@instance, claude(), room, on_behalf_of: ada())
    {:ok, %{"state" => %{"title" => title}}} = Participant.open(agent, room)
    title
  end

  test "the component's button and the agent's tool change its document, each as itself", %{
    room: room,
    ctx: ctx,
    tools: tools
  } do
    {:ok, view, _} =
      live_isolated(build_conn(), IsshoTest.BoardLive,
        session: %{"user" => "user:ada", "room" => room}
      )

    render_click(view, "retitle", %{"title" => "Ada's plan"})
    settle(view.pid)
    assert render(view) =~ "retitled"
    assert_receive {Issho, :event, %Event{name: "document.changed", by: %{key: "user:ada"}}}
    assert_receive {Issho, :event, %Event{name: "action.done", by: %{key: "user:ada"}}}
    assert title(room) == "Ada's plan"

    assert {:ok, "Retitled."} =
             Tools.call(
               tools,
               "retitle_board",
               %{"board" => room, "title" => "Claude's plan"},
               ctx
             )

    assert_receive {Issho, :event, %Event{name: "document.changed", by: %{key: "agent:claude"}}}
    assert title(room) == "Claude's plan"

    # Each reads the document as itself first: the same check refuses both.
    assert {:error, "It is already \"Claude's plan\"."} =
             Tools.call(
               tools,
               "retitle_board",
               %{"board" => room, "title" => "Claude's plan"},
               ctx
             )

    render_click(view, "retitle", %{"title" => "Claude's plan"})
    settle(view.pid)
    assert render(view) =~ "retitled:It is already"

    # It went to the title first, seen there.
    agent = Agents.participant(@instance, "agent:claude", room)
    assert %{"place" => %{"at" => %{"path" => ["title"]}}} = Participant.awareness(agent)
  end

  test "paused on its way, it changes nothing; at once, there is no way", %{
    room: room,
    ctx: ctx,
    tools: tools
  } do
    {:ok, ada} = Issho.join_as(@instance, ada(), room)
    {:present, %{session: session}} = :sys.get_state(ada)
    {:ok, agent} = Agents.join(@instance, claude(), room, on_behalf_of: ada())
    {:ok, _} = Tools.call(tools, "start_task", %{"room" => room, "title" => "Retitle"}, ctx)

    :persistent_term.put({IsshoTest.Retitle, :waiter}, self())
    on_exit(fn -> :persistent_term.erase({IsshoTest.Retitle, :waiter}) end)

    task =
      Task.async(fn ->
        Tools.call(tools, "retitle_board", %{"board" => room, "title" => "Too late"}, ctx)
      end)

    assert_receive {:on_the_way, runner}
    :ok = Issho.Session.interrupt(session, "agent:claude", :pause)
    assert_receive {Issho, :event, %Event{name: "agent.interrupted"}}
    settle(agent)
    send(runner, :go)

    assert {:error, "Ada paused you" <> _} = Task.await(task)
    assert title(room) == "Untitled"
    refute_received {Issho, :event, %Event{name: "action.done"}}

    :ok = Issho.Session.interrupt(session, "agent:claude", :resume)
    assert_receive {Issho, :event, %Event{name: "agent.resumed"}}
    settle(agent)
    :persistent_term.erase({IsshoTest.Retitle, :waiter})

    # At once: the same change, and no gesture (no wait for :go).
    assert {:ok, _receipt} =
             Action.invoke(
               @instance,
               IsshoTest.Retitle,
               %{board: room, title: "At once"},
               claude(),
               on_behalf_of: ada(),
               visible: false
             )

    assert title(room) == "At once"
    refute_received {:on_the_way, _}
  end

  test "your code with no way to the room is told so", %{room: room} do
    assert {:error, :not_in_room} =
             Action.invoke(@instance, IsshoTest.Retitle, %{board: room, title: "No"}, ada())
  end

  test "an agent finds what it may do in a room, and why not", %{
    ctx: ctx,
    tools: tools,
    room: room
  } do
    assert {:ok, %{"actions" => actions}} =
             Tools.call(tools, "list_actions", %{"room" => room}, ctx)

    assert [
             %{name: "retitle_board", allowed: true},
             %{name: "check_item", allowed: true}
           ] = actions

    readonly = "readonly:" <> Transaction.id()

    assert {:ok, %{"actions" => [%{allowed: false, why: why}, %{allowed: false}]}} =
             Tools.call(tools, "list_actions", %{"room" => readonly}, ctx)

    assert why =~ "policy"

    canvas = "canvas:" <> Transaction.id()

    assert {:ok,
            %{"actions" => [%{allowed: false, why: "A canvas has no title."}, %{allowed: true}]}} =
             Tools.call(tools, "list_actions", %{"room" => canvas}, ctx)

    IsshoTest.Policy.deny("agent:claude")
    on_exit(fn -> IsshoTest.Policy.allow("agent:claude") end)

    assert {:error, "The room's policy does not allow this."} =
             Tools.call(tools, "list_actions", %{"room" => room}, ctx)
  end
end
