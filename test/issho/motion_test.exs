defmodule Issho.MotionTest do
  use ExUnit.Case, async: false

  alias Issho.{Motion, Participant, Tool, Tools, Transaction}

  @instance IsshoTest.Issho

  setup do
    room = "notebook:" <> Transaction.id()
    doc = room <> "/body"
    {:ok, ken} = Issho.join_as(@instance, %{id: "user:ken", name: "Ken"}, room)
    {:ok, agent} = Issho.join_as(@instance, %{id: "agent:one", name: "Agent", kind: :agent}, room)
    Application.put_env(:issho, Motion, flight: 40, step: 20, click: 10)
    on_exit(fn -> Application.delete_env(:issho, Motion) end)
    %{room: room, doc: doc, ken: ken, agent: agent}
  end

  defp view(ken, view), do: :ok = Participant.aware(ken, %{"view" => view})

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {div(us, 1000), result}
  end

  test "a gesture says where the agent goes, once, and its place in a document", %{
    doc: doc,
    ken: ken,
    agent: agent
  } do
    target = %{"doc" => doc, "at" => %{"cell" => [1, "name"]}}
    :ok = Motion.go(agent, target)

    assert_receive {Participant, ^ken, "aware", %{"states" => states}}, 1_000

    assert [%{"state" => %{"motion" => motion, "place" => place}}] =
             for({_, %{"key" => "agent:one"} = s} <- states, do: s)

    assert %{"to" => ^target, "gesture" => "move", "ms" => 40, "seq" => 1} = motion
    assert place == target

    # Within the same document, a step; then a click on an element of the page.
    :ok = Motion.go(agent, %{"doc" => doc, "at" => %{"cell" => [2, "name"]}})
    assert %{"motion" => %{"ms" => 20, "seq" => 2}} = Participant.awareness(agent)

    # An element of the page is not a place of a document: the place stays.
    :ok = Motion.click(agent, %{"anchor" => "edit"})

    assert %{
             "motion" => %{"gesture" => "click", "to" => %{"anchor" => "edit"}, "seq" => 3},
             "place" => %{"at" => %{"cell" => [2, "name"]}}
           } =
             Participant.awareness(agent)
  end

  test "it moves for someone who sees it, and not for no one", %{doc: doc, ken: ken, agent: agent} do
    target = %{"doc" => doc, "at" => 1}

    # A browser that says nothing of what it shows: watching.
    assert Motion.watched?(agent, target)

    view(ken, %{"page" => true, "docs" => [doc], "motion" => "full"})
    assert Motion.watched?(agent, target)

    # The document off the screen, the page in the background, or no motion wanted.
    view(ken, %{"page" => true, "docs" => ["elsewhere"], "motion" => "full"})
    refute Motion.watched?(agent, target)
    assert Motion.watched?(agent, %{"anchor" => "edit"})

    view(ken, %{"page" => false, "docs" => [doc], "motion" => "full"})
    refute Motion.watched?(agent, target)

    view(ken, %{"page" => true, "docs" => [doc], "motion" => "reduced"})
    refute Motion.watched?(agent, target)

    # Following the agent: wherever it goes.
    view(ken, %{"page" => true, "docs" => [], "motion" => "full", "follow" => "agent:one"})
    assert Motion.watched?(agent, target)

    # Unseen, it is there at once.
    view(ken, %{"page" => false, "docs" => [], "motion" => "full"})
    {ms, :ok} = timed(fn -> Motion.go(agent, target) end)
    assert ms < 20
    assert %{"motion" => %{"ms" => 0}} = Participant.awareness(agent)
  end

  test "a tool call's gestures together stay within its budget", %{doc: doc, agent: agent} do
    Application.put_env(:issho, Motion, flight: 200, step: 200, budget: 300)

    {ms, :ok} =
      timed(fn ->
        Motion.within(fn ->
          for n <- 1..5, do: :ok = Motion.go(agent, %{"doc" => doc, "at" => n}, place: false)
          :ok
        end)
      end)

    assert ms >= 290 and ms < 450
    assert %{"motion" => %{"ms" => 0, "seq" => 5}} = Participant.awareness(agent)
  end

  test "travel: false, and agents are there at once", %{doc: doc, agent: agent} do
    Application.put_env(:issho, Motion, travel: false)
    {ms, :ok} = timed(fn -> Motion.go(agent, %{"doc" => doc, "at" => 1}) end)
    assert ms < 20
  end

  test "agents point at and click the elements the people's pages name", %{room: room, ken: ken} do
    view(ken, %{
      "page" => true,
      "docs" => [],
      "motion" => "full",
      "anchors" => [%{"name" => "edit", "label" => "Edit together", "follow" => true}]
    })

    ctx = Tool.Context.new(@instance, %{id: "assistant:ada", name: "Assistant", kind: :agent})

    assert {:ok,
            %{"anchors" => [%{"name" => "edit", "label" => "Edit together", "follow" => true}]}} =
             Tools.call(Tools.room(), "look_around", %{"room" => room}, ctx)

    assert {:ok, "Clicked."} =
             Tools.call(Tools.room(), "click", %{"room" => room, "anchor" => "edit"}, ctx)

    assert_receive {Participant, ^ken, "aware", %{"states" => states}}, 1_000

    assert Enum.any?(states, fn {_, s} ->
             match?(
               %{
                 "key" => "assistant:ada",
                 "state" => %{"motion" => %{"gesture" => "click", "to" => %{"anchor" => "edit"}}}
               },
               s
             )
           end)
  end
end
