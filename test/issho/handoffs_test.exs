defmodule Issho.HandoffsTest do
  # An agent hands a task to another: it goes to that agent alone, in the
  # room or its inbox, with who the first works for; the agent answers,
  # and only it can, and the first hears the answer.
  use ExUnit.Case, async: false

  alias Issho.{Agents, Events, Handoffs, Tool, Tools, Transaction}

  @instance IsshoTest.Issho

  defp ada, do: %{id: "user:ada", name: "Ada"}
  defp helper, do: %{id: "agent:ada-helper", name: "Ada's helper", kind: :agent}
  defp gardener, do: %{id: "bot:gardener", name: "Gardener", kind: :service}
  defp kens, do: %{id: "agent:ken-helper", name: "Ken's helper", kind: :agent}

  setup do
    room = "board:" <> Transaction.id()
    on_exit(fn -> IsshoTest.Policy.allow("agent:ada-helper") end)

    for key <- ["agent:ada-helper", "bot:gardener", "agent:ken-helper"],
        do: :ok = Issho.Inbox.mark_read(@instance, key, :all)

    helper = Tool.Context.new(@instance, helper(), on_behalf_of: ada())
    gardener = Tool.Context.new(@instance, gardener())
    %{room: room, helper: helper, gardener: gardener}
  end

  defp inbox(actor, tries \\ 50) do
    case Issho.Inbox.items(@instance, actor) do
      {:ok, [_ | _] = items} -> items
      _ when tries > 0 -> Process.sleep(10) && inbox(actor, tries - 1)
      other -> other
    end
  end

  test "in the room, the agent handed it hears it with whom it is for, and no one else", %{
    room: room
  } do
    {:ok, _} = Agents.join(@instance, gardener(), room)
    {:ok, _} = Agents.join(@instance, kens(), room)
    :ok = Events.subscribe(@instance, room)

    {:ok, handoff} =
      Handoffs.hand_off(@instance, room, helper(), "bot:gardener", "Tidy the tags",
        on_behalf_of: ada(),
        data: %{"folder" => 3}
      )

    assert handoff.for.key == "user:ada"

    assert {:ok, [event]} =
             Agents.wait(@instance, "bot:gardener", room, ["agent.handed_off"], 1_000)

    assert %{by: %{key: "agent:ada-helper"}, to: ["bot:gardener"]} = event

    assert %{
             handoff: id,
             task: "Tidy the tags",
             data: %{"folder" => 3},
             for: %{"key" => "user:ada"}
           } =
             event.data

    assert id == handoff.id
    assert {:ok, []} = Agents.wait(@instance, "agent:ken-helper", room, ["agent.handed_off"], 100)
    refute_received {Issho, :event, %{name: "agent.handed_off"}}
  end

  test "away, it waits in the agent's inbox; it answers, and the hander hears", %{
    room: room,
    helper: helper,
    gardener: gardener
  } do
    assert {:ok, %{"handoff" => id, "to" => "bot:gardener"}} =
             Tools.call(
               Tools.room(),
               "hand_off",
               %{"room" => room, "to" => "bot:gardener", "task" => "Tidy the tags"},
               helper
             )

    # Delivered a moment after.
    assert [_] = inbox(gardener())
    assert {:ok, %{"items" => [item]}} = Tools.call(Tools.room(), "inbox", %{}, gardener)

    assert %{
             "event" => "agent.handed_off",
             "handoff" => ^id,
             "task" => "Tidy the tags",
             "for" => "Ada"
           } =
             item

    assert {:ok, %{"status" => "done"}} =
             Tools.call(
               Tools.room(),
               "answer_handoff",
               %{"handoff" => id, "status" => "done", "text" => "Twelve tags, now seven."},
               gardener
             )

    assert [%{"name" => "agent.handoff_replied", "data" => data}] = inbox(helper())
    assert %{"status" => "done", "text" => "Twelve tags, now seven.", "handoff" => ^id} = data
  end

  test "by its name in the room, the tool finds the agent", %{room: room, helper: helper} do
    {:ok, _} = Agents.join(@instance, gardener(), room)

    assert {:ok, %{"to" => "bot:gardener"}} =
             Tools.call(
               Tools.room(),
               "hand_off",
               %{"room" => room, "to" => "Gardener", "task" => "Tidy"},
               helper
             )
  end

  test "only the agent handed it answers, with a status it knows", %{room: room, helper: helper} do
    {:ok, handoff} = Handoffs.hand_off(@instance, room, helper(), "bot:gardener", "Tidy")

    assert {:error, :not_yours} = Handoffs.reply(@instance, handoff.id, kens(), "done")
    assert {:error, :unknown_status} = Handoffs.reply(@instance, handoff.id, gardener(), "maybe")
    assert {:error, :invalid} = Handoffs.reply(@instance, "nope", gardener(), "done")

    assert {:error, "That task was handed to another agent, not you."} =
             Tools.call(
               Tools.room(),
               "answer_handoff",
               %{"handoff" => handoff.id, "status" => "done"},
               helper
             )
  end

  test "the policy says who hands off to whom; people and yourself are not handed to", %{
    room: room,
    helper: helper
  } do
    assert {:error, :forbidden} =
             Handoffs.hand_off(@instance, room, helper(), "user:ken", "Do it")

    assert {:error, :not_an_agent} =
             Handoffs.hand_off(@instance, room, ada(), "bot:gardener", "Do it")

    assert {:error, :to_yourself} =
             Handoffs.hand_off(@instance, room, helper(), "agent:ada-helper", "Do it")

    assert {:error, :empty_task} =
             Handoffs.hand_off(@instance, room, helper(), "bot:gardener", "  ")

    IsshoTest.Policy.deny("agent:ada-helper")

    assert {:error, "The room's policy" <> _} =
             Tools.call(
               Tools.room(),
               "hand_off",
               %{"room" => room, "to" => "bot:x", "task" => "Do it"},
               helper
             )
  end
end
