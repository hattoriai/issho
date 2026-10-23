defmodule Issho.CommentsTest do
  # Threads of comments on the places of a room: from the server, from a
  # session under the policy, and from agents, with their events.
  use ExUnit.Case, async: false

  import IsshoTest.Sync

  alias Issho.{Comments, Event, Events, Identity, Participant, Tool, Tools, Transaction}
  alias Issho.Comments.Ops

  doctest Issho.Comments

  @instance IsshoTest.Issho

  setup do
    room = "board:" <> Transaction.id()
    :ok = Events.subscribe(@instance, room)
    %{room: room, place: %{"doc" => room, "at" => %{"path" => ["title"]}}}
  end

  defp ada, do: %{id: "user:ada", name: "Ada"}
  defp ken, do: %{id: "user:ken", name: "Ken"}
  defp claude, do: %{id: "agent:claude", name: "Claude", kind: :agent}

  describe "from the server" do
    test "a thread, its replies, reactions, edits, resolving", %{room: room, place: place} do
      {:ok, %{thread: thread, comment: first}} =
        Comments.start(@instance, room, ada(), place, "Should this go first?",
          mentions: ["user:ken"]
        )

      {:ok, %{comment: reply}} = Comments.reply(@instance, room, ken(), thread, "Yes.")
      {:ok, _} = Comments.react(@instance, room, ken(), thread, first, "👍")

      {:ok, _} =
        Comments.edit(@instance, room, ada(), thread, first, "Should this go first? It blocks.",
          mentions: ["user:ken"]
        )

      {:ok, _} = Comments.resolve(@instance, room, ken(), thread)

      assert {:ok, [t]} = Comments.threads(@instance, room)
      assert %{"id" => ^thread, "place" => ^place, "status" => "resolved"} = t
      assert %{"by" => "user:ken", "at" => _} = t["resolved"]

      assert [
               %{
                 "id" => ^first,
                 "author" => %{"key" => "user:ada", "name" => "Ada", "kind" => "human"},
                 "body" => "Should this go first? It blocks.",
                 "mentions" => ["user:ken"],
                 "edited" => edited,
                 "reactions" => %{"👍" => ["user:ken"]}
               },
               %{"id" => ^reply, "author" => %{"key" => "user:ken"}, "body" => "Yes."}
             ] = t["comments"]

      assert is_binary(edited)

      {:ok, _} = Comments.reopen(@instance, room, ada(), thread)
      {:ok, _} = Comments.unreact(@instance, room, ken(), thread, first, "👍")
      {:ok, _} = Comments.delete(@instance, room, ken(), thread, reply)

      assert {:ok, [%{"status" => "open", "comments" => [%{"reactions" => %{}}]}]} =
               Comments.threads(@instance, room)

      {:ok, _} = Comments.delete(@instance, room, ada(), thread, first)
      assert {:ok, []} = Comments.threads(@instance, room)
    end

    test "only its author edits or deletes a comment", %{room: room} do
      {:ok, %{thread: thread, comment: comment}} =
        Comments.start(@instance, room, ada(), nil, "Mine")

      assert {:error, :not_the_author} =
               Comments.edit(@instance, room, ken(), thread, comment, "Ken's")

      assert {:error, :not_the_author} = Comments.delete(@instance, room, ken(), thread, comment)
    end

    test "the events of each change, once it is saved", %{room: room, place: place} do
      {:ok, %{thread: thread, comment: first}} =
        Comments.start(@instance, room, ada(), place, "Look", mentions: ["agent:claude"])

      document = Comments.document(room)

      assert_receive {Issho, :event,
                      %Event{
                        name: "thread.created",
                        document: ^document,
                        by: %Identity{key: "user:ada"},
                        data: %{
                          thread: ^thread,
                          comment: ^first,
                          place: ^place,
                          body: "Look",
                          mentions: ["agent:claude"]
                        }
                      }}

      assert_receive {Issho, :event,
                      %Event{name: "comment.created", data: %{reply: false, thread: ^thread}}}

      {:ok, %{comment: reply}} = Comments.reply(@instance, room, ken(), thread, "Seen")

      assert_receive {Issho, :event,
                      %Event{
                        name: "comment.created",
                        data: %{reply: true, comment: ^reply, place: ^place}
                      }}

      {:ok, _} = Comments.edit(@instance, room, ken(), thread, reply, "Seen it")
      assert_receive {Issho, :event, %Event{name: "comment.edited", data: %{body: "Seen it"}}}

      {:ok, _} = Comments.resolve(@instance, room, ada(), thread)
      assert_receive {Issho, :event, %Event{name: "thread.resolved", data: %{thread: ^thread}}}
      {:ok, _} = Comments.reopen(@instance, room, ada(), thread)
      assert_receive {Issho, :event, %Event{name: "thread.reopened"}}
      {:ok, _} = Comments.delete(@instance, room, ken(), thread, reply)
      assert_receive {Issho, :event, %Event{name: "comment.deleted", data: %{comment: ^reply}}}
    end

    test "the comments document is Issho's, whatever the policy says", %{room: room} do
      {:ok, pid} = Issho.Documents.open(@instance, Comments.document(room))

      assert {:ok, %{"engine" => "issho.comments", "state" => %{"threads" => []}}} =
               Issho.Authority.snapshot(pid)
    end
  end

  describe "held to the writer" do
    setup %{room: room} do
      {:ok, ken} = Issho.join_as(@instance, ken(), room)
      {:ok, _} = Participant.open(ken, Comments.document(room))
      %{ken: ken, document: Comments.document(room)}
    end

    test "no one writes as someone else", %{ken: ken, document: document} do
      {op, _} = Ops.start(Identity.new(ada()), nil, "Not Ken")
      assert {:error, :not_the_author} = Participant.transact(ken, document, [op])

      # Ken's key, another name.
      {op, _} = Ops.start(Identity.new(%{id: "user:ken", name: "Ada"}), nil, "Ken as Ada")
      assert {:error, :not_the_author} = Participant.transact(ken, document, [op])

      {op, _} = Ops.start(Identity.new(ken()), nil, "Ken")
      assert {:ok, _} = Participant.transact(ken, document, [op])
    end

    test "nor in the past, nor elsewhere", %{ken: ken, document: document, room: room} do
      {op, _} = Ops.start(Identity.new(ken()), nil, "Long ago")
      op = put_in(op, ["comment", "at"], "2020-01-01T00:00:00Z")
      assert {:error, :invalid_time} = Participant.transact(ken, document, [op])

      {op, _} = Ops.start(Identity.new(ken()), %{"doc" => "board:other"}, "Elsewhere")
      assert {:error, :other_room} = Participant.transact(ken, document, [op])

      {op, _} = Ops.start(Identity.new(ken()), %{"doc" => room <> "/rows"}, "Here")
      assert {:ok, _} = Participant.transact(ken, document, [op])
    end
  end

  test "a reader comments when the policy allows :comment" do
    room = "readonly:" <> Transaction.id()
    {:ok, reader} = Issho.join_as(@instance, ken(), room, can: :read)
    document = Comments.document(room)
    {:ok, _} = Participant.open(reader, document)

    {op, _} = Ops.start(Identity.new(ken()), nil, "A reader's question")
    assert {:ok, _} = Participant.transact(reader, document, [op])

    # Not the room's other documents.
    {:ok, _} = Participant.open(reader, room)

    assert {:error, :read_only} =
             Participant.transact(reader, room, [%{"op" => "set", "path" => ["a"], "value" => 1}])
  end

  test "a policy that does not allow :comment" do
    room = "board:" <> Transaction.id()
    {:ok, ken} = Issho.join_as(@instance, ken(), room)
    {:ok, _} = Participant.open(ken, Comments.document(room))
    IsshoTest.Policy.deny_action(:comment)
    on_exit(fn -> IsshoTest.Policy.allow_action(:comment) end)

    {op, _} = Ops.start(Identity.new(ken()), nil, "No")
    assert {:error, :forbidden} = Participant.transact(ken, Comments.document(room), [op])
  end

  describe "agents" do
    setup %{room: room} do
      ctx = Tool.Context.new(@instance, claude(), on_behalf_of: ada())
      %{ctx: ctx, tools: Tools.room(), key: "agent:claude", room: room}
    end

    test "an agent mentioned in a thread hears it, and answers there", %{
      ctx: ctx,
      tools: tools,
      room: room,
      place: place
    } do
      {:ok, _} = Tools.call(tools, "join_room", %{"room" => room}, ctx)

      {:ok, %{thread: thread}} =
        Comments.start(@instance, room, ada(), place, "@Claude, what goes here?",
          mentions: ["agent:claude"]
        )

      {:ok, _} = Comments.start(@instance, room, ken(), nil, "Not for the agent")
      settle_agent("agent:claude", room)

      assert {:ok,
              %{"events" => [%{"name" => "comment.created", "data" => %{"thread" => ^thread}}]}} =
               Tools.call(
                 tools,
                 "wait_for_events",
                 %{
                   "room" => room,
                   "names" => ["comment.created"],
                   "mentions_me" => true,
                   "seconds" => 0
                 },
                 ctx
               )

      assert {:ok, %{"thread" => ^thread, "comment" => _}} =
               Tools.call(
                 tools,
                 "comment",
                 %{
                   "room" => room,
                   "thread" => thread,
                   "body" => "The title.",
                   "mentions" => ["user:ada"]
                 },
                 ctx
               )

      assert {:ok, %{"threads" => [%{"thread" => ^thread, "comments" => [_, answer]}, _]}} =
               Tools.call(tools, "list_threads", %{"room" => room}, ctx)

      assert %{
               "by" => "Claude",
               "key" => "agent:claude",
               "body" => "The title.",
               "mentions" => ["user:ada"]
             } = answer

      {:ok, [%{"comments" => [_, %{"author" => author}]} | _]} = Comments.threads(@instance, room)
      assert author["on_behalf_of"] == %{"key" => "user:ada", "name" => "Ada"}

      assert {:ok, "Resolved."} =
               Tools.call(tools, "resolve_thread", %{"room" => room, "thread" => thread}, ctx)

      assert {:ok, %{"threads" => [_]}} =
               Tools.call(tools, "list_threads", %{"room" => room}, ctx)

      assert {:ok, %{"threads" => [%{"status" => "resolved"}]}} =
               Tools.call(tools, "list_threads", %{"room" => room, "status" => "resolved"}, ctx)
    end

    test "a new thread at a place, at what someone selected, or on the page", %{
      ctx: ctx,
      tools: tools,
      room: room,
      place: place
    } do
      {:ok, ada} = Issho.join_as(@instance, ada(), room)
      :ok = Participant.place(ada, place)

      assert {:ok, %{"thread" => at_ada}} =
               Tools.call(
                 tools,
                 "comment",
                 %{"room" => room, "body" => "Here?", "of" => "Ada"},
                 ctx
               )

      assert {:ok, %{"thread" => at_path}} =
               Tools.call(
                 tools,
                 "comment",
                 %{"room" => room, "body" => "There", "at" => %{"path" => ["body"]}},
                 ctx
               )

      assert {:ok, %{"thread" => on_page}} =
               Tools.call(tools, "comment", %{"room" => room, "body" => "All of it"}, ctx)

      {:ok, threads} = Comments.threads(@instance, room)
      places = Map.new(threads, &{&1["id"], &1["place"]})

      assert places == %{
               at_ada => place,
               at_path => %{"doc" => room, "at" => %{"path" => ["body"]}},
               on_page => nil
             }

      assert {:error, "No one called \"Zed\" is in the room."} =
               Tools.call(
                 tools,
                 "comment",
                 %{"room" => room, "body" => "Hi", "mentions" => ["Zed"]},
                 ctx
               )
    end
  end

  defp settle_agent(key, room) do
    settle(Issho.Agents.participant(@instance, key, room))
    agent = Issho.Agents.whereis(@instance, key, room)
    settle(agent)
  end
end
