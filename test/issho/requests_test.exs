defmodule Issho.RequestsTest do
  # A person asks their agent privately about what they selected: the
  # agent hears it, in the room or in its inbox, and no one else does; it
  # answers with a stream at the place; the person takes it (a change made
  # only on the version they saw, once) or leaves it, and the agent hears
  # which, privately too.
  use ExUnit.Case, async: false

  alias Issho.{Agents, Authority, Documents, Events, Requests, Streams, Tool, Tools, Transaction}

  @instance IsshoTest.Issho

  defp ada, do: %{id: "user:ada", name: "Ada"}
  defp ken, do: %{id: "user:ken", name: "Ken"}
  defp helper, do: %{id: "agent:ada-helper", name: "Ada's helper", kind: :agent}
  defp kens, do: %{id: "agent:ken-helper", name: "Ken's helper", kind: :agent}

  defp set(key, value), do: %{"op" => "set", "path" => [key], "value" => value}

  setup do
    room = "board:" <> Transaction.id()
    {:ok, pid} = Documents.open(@instance, room)
    {:ok, snapshot} = Authority.snapshot(pid)
    place = %{"doc" => room, "at" => %{"path" => ["title"]}, "label" => "Untitled"}
    ctx = Tool.Context.new(@instance, helper(), on_behalf_of: ada())

    on_exit(fn -> IsshoTest.Policy.allow("user:ada") end)

    # The agents' inboxes outlive a test.
    for key <- ["agent:ada-helper", "agent:ken-helper"],
        do: :ok = Issho.Inbox.mark_read(@instance, key, :all)

    %{room: room, place: place, version: Issho.Version.of(snapshot), ctx: ctx}
  end

  defp ask(room, place, version, opts \\ []) do
    Requests.ask(
      @instance,
      room,
      ada(),
      Keyword.get(opts, :text, "Make this shorter"),
      Keyword.merge(
        [agent: "agent:ada-helper", place: place, version: version, data: %{"block" => "b1"}],
        opts
      )
    )
  end

  defp inbox(actor, person, tries \\ 50) do
    case Issho.Inbox.items(@instance, actor, on_behalf_of: person) do
      {:ok, [_ | _] = items} -> items
      _ when tries > 0 -> Process.sleep(10) && inbox(actor, person, tries - 1)
      other -> other
    end
  end

  # The agent answers: a stream for its person, at the place, with the request.
  defp answer(ctx, room, request, text) do
    {:ok, %{"stream" => stream}} =
      Tools.call(
        Tools.room(),
        "start_stream",
        %{
          "room" => room,
          "kind" => "suggestion",
          "request" => request.id,
          "document" => request.place["doc"],
          "at" => request.place["at"]
        },
        ctx
      )

    {:ok, _} =
      Tools.call(Tools.room(), "append_to_stream", %{"stream" => stream, "text" => text}, ctx)

    {:ok, _} = Tools.call(Tools.room(), "finish_stream", %{"stream" => stream}, ctx)
    stream
  end

  test "in the room, the agent asked hears it, and no one else", %{
    room: room,
    place: place,
    version: version,
    ctx: ctx
  } do
    {:ok, _} = Agents.join(@instance, helper(), room, on_behalf_of: ada())
    {:ok, _} = Agents.join(@instance, kens(), room, on_behalf_of: ken())
    :ok = Events.subscribe(@instance, room)

    {:ok, request} =
      ask(room, place, version, text: "Make this" <> <<0x202E::utf8>> <> " shorter")

    assert request.text == "Make this shorter"

    assert {:ok, [event]} =
             Agents.wait(@instance, "agent:ada-helper", room, ["agent.asked"], 1_000)

    assert %{name: "agent.asked", by: %{key: "user:ada"}, to: ["agent:ada-helper"]} = event

    assert event.data == %{
             request: request.id,
             text: "Make this shorter",
             place: place,
             version: version,
             data: %{"block" => "b1"}
           }

    # Not Ken's agent, not the room's subscribers.
    assert {:ok, []} = Agents.wait(@instance, "agent:ken-helper", room, ["agent.asked"], 100)
    refute_received {Issho, :event, %{name: "agent.asked"}}

    # Heard in the room, it is read in its inbox: it comes once.
    assert [%{"data" => %{"request" => id}}] = inbox(helper(), ada())
    assert id == request.id

    {:ok, %{"events" => []}} =
      Tools.call(
        Tools.room(),
        "wait_for_events",
        %{"room" => room, "seconds" => 0, "names" => ["agent.asked"]},
        ctx
      )

    _ = Issho.Inbox.heard(@instance, "agent:ada-helper", [event])
    assert {:ok, []} = Issho.Inbox.items(@instance, helper(), on_behalf_of: ada())
  end

  test "away, it is in its inbox, for it alone", %{
    room: room,
    place: place,
    version: version,
    ctx: ctx
  } do
    {:ok, request} = ask(room, place, version)

    assert [%{"name" => "agent.asked"}] = inbox(helper(), ada())
    assert {:ok, []} = Issho.Inbox.items(@instance, kens(), on_behalf_of: ken())

    {:ok, %{"items" => [item]}} = Tools.call(Tools.room(), "inbox", %{}, ctx)

    assert %{
             "event" => "agent.asked",
             "request" => id,
             "text" => "Make this shorter",
             "place" => %{"label" => "Untitled"},
             "version" => ^version,
             "data" => %{"block" => "b1"},
             "yours" => true
           } = item

    assert id == request.id
  end

  test "the policy says who may ask whom; the words are bounded", %{
    room: room,
    place: place,
    version: version
  } do
    assert {:error, :forbidden} = ask(room, place, version, agent: "agent:ken-helper")
    assert {:error, :no_agent} = ask(room, place, version, agent: nil)

    assert {:error, :empty_request} =
             ask(room, place, version, text: " " <> <<0x202E::utf8>> <> " ")

    assert {:error, :too_large} =
             ask(room, place, version, data: %{"x" => String.duplicate("a", 5_000)})

    assert {:error, :invalid_version} = ask(room, place, version, version: "41")
    assert {:error, :other_room} = ask(room, %{place | "doc" => "board:elsewhere"}, version)

    IsshoTest.Policy.deny("user:ada")
    assert {:error, :forbidden} = ask(room, place, version)

    # A policy that says nothing of asking lets no one ask.
    defmodule Silent do
      def authorize(_identity, _room, _action), do: :ok
    end

    assert {:error, :forbidden} =
             Issho.Policy.ask(Silent, Issho.Identity.new(ada()), room, "agent:ada-helper")
  end

  test "answered in place, taken once, and its agent hears it was, privately", %{
    room: room,
    place: place,
    version: version,
    ctx: ctx
  } do
    {:ok, _} = Agents.join(@instance, kens(), room, on_behalf_of: ken())
    {:ok, request} = ask(room, place, version)
    stream = answer(ctx, room, request, "Short.")

    {:ok, answer} = Streams.get(@instance, stream)
    assert %{for: "user:ada", meta: %{request: id}, content: "Short."} = answer
    assert Map.take(answer.place, ["doc", "at"]) == Map.take(place, ["doc", "at"])
    assert id == request.id

    take = fn request ->
      Issho.transact(@instance, room, [set("title", "Short.")],
        if_revision: request.version,
        author: ada()
      )
    end

    # Not by another person, nor by the agent that wrote it.
    assert {:error, :forbidden} = Requests.accept(@instance, request, stream, ken(), take)

    assert {:error, :forbidden} =
             Requests.accept(
               @instance,
               request,
               stream,
               Issho.Identity.new(helper(), on_behalf_of: ada()),
               take
             )

    assert {:ok, %{"revision" => 1}} = Requests.accept(@instance, request, stream, ada(), take)
    assert {:error, :closed} = Requests.accept(@instance, request, stream, ada(), take)

    assert {:ok, %{"revision" => 1}} =
             Authority.snapshot(elem(Documents.open(@instance, room), 1))

    assert {:ok, events} =
             Agents.wait(@instance, "agent:ada-helper", room, ["stream.closed"], 1_000)

    assert [%{data: %{outcome: "accepted", request: ^id}}] = events
    assert {:ok, []} = Agents.wait(@instance, "agent:ken-helper", room, ["stream.*"], 100)
  end

  test "a selection changed since is not taken: the suggestion stays, to leave", %{
    room: room,
    place: place,
    version: version,
    ctx: ctx
  } do
    {:ok, request} = ask(room, place, version)
    stream = answer(ctx, room, request, "Short.")
    {:ok, _} = Issho.transact(@instance, room, [set("title", "Ken's")], author: ken())

    take = fn request ->
      Issho.transact(@instance, room, [set("title", "Short.")],
        if_revision: request.version,
        author: ada()
      )
    end

    assert {:error, {:stale, %{"count" => 1}}} =
             Requests.accept(@instance, request, stream, ada(), take)

    assert {:ok, %{state: :finished}} = Streams.get(@instance, stream)

    assert :ok = Requests.reject(@instance, request, stream, ada())
    assert {:error, :closed} = Requests.reject(@instance, request, stream, ada())

    assert {:ok, %{"state" => %{"title" => "Ken's"}}} =
             Authority.snapshot(elem(Documents.open(@instance, room), 1))
  end

  test "taken at once in two places, the change is made once", %{
    room: room,
    place: place,
    version: version,
    ctx: ctx
  } do
    {:ok, request} = ask(room, place, version)
    stream = answer(ctx, room, request, "Short.")

    take = fn _request ->
      Issho.transact(@instance, room, [%{"op" => "increment", "path" => ["taken"], "by" => 1}],
        author: ada()
      )
    end

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn -> Requests.accept(@instance, request, stream, ada(), take) end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :closed})) == 1

    {:ok, %{"state" => state}} = Authority.snapshot(elem(Documents.open(@instance, room), 1))
    assert state["taken"] == 1
  end

  test "an answer to another request, or from another agent, is not taken; nor after access goes",
       %{room: room, place: place, version: version, ctx: ctx} do
    {:ok, request} = ask(room, place, version)
    {:ok, other} = ask(room, place, version)
    stream = answer(ctx, room, other, "Not this one.")
    ok = fn _ -> {:ok, :made} end

    assert {:error, :not_the_answer} = Requests.accept(@instance, request, stream, ada(), ok)

    stream = answer(ctx, room, request, "This one.")
    IsshoTest.Policy.deny("user:ada")
    assert {:error, :forbidden} = Requests.accept(@instance, request, stream, ada(), ok)
    IsshoTest.Policy.allow("user:ada")
    assert {:ok, :made} = Requests.accept(@instance, request, stream, ada(), ok)
  end
end
