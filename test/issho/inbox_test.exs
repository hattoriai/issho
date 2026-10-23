defmodule Issho.InboxTest do
  # What was said to someone while they were away: comments that mention
  # them, kept in their inbox, read by the inbox tool, over MCP, and the
  # app's hook that wakes them.
  use ExUnit.Case, async: false

  import Sake.Test

  alias Issho.{Comments, Config, Inbox, Participant, Tool, Tools, Transaction}

  @instance IsshoTest.Issho

  defp ada, do: %{id: "user:ada", name: "Ada"}
  defp ken, do: %{id: "user:ken", name: "Ken"}

  setup do
    claude = %{id: "agent:claude:" <> Transaction.id(), name: "Claude", kind: :agent}
    %{room: "board:" <> Transaction.id(), claude: claude, key: claude.id}
  end

  # The inbox's items once `count` are delivered: delivery runs apart
  # from the comment.
  defp items(actor, count \\ 1, tries \\ 50) do
    case Inbox.items(@instance, actor) do
      {:ok, found} when length(found) >= count ->
        {:ok, found}

      _ when tries > 0 ->
        Process.sleep(10)
        items(actor, count, tries - 1)

      other ->
        other
    end
  end

  test "a comment that mentions someone away is in their inbox", %{
    room: room,
    claude: claude,
    key: key
  } do
    # Inboxes last from test to test: an author of this test's own.
    grace = %{id: "user:grace:" <> Transaction.id(), name: "Grace"}

    {:ok, %{thread: thread, comment: comment}} =
      Comments.start(@instance, room, grace, nil, "@Claude, a look?", mentions: [key, grace.id])

    assert {:ok, [item]} = items(claude)

    assert %{
             "name" => "comment.created",
             "room" => ^room,
             "read" => false,
             "by" => %{"name" => "Grace"},
             "data" => %{"thread" => ^thread, "comment" => ^comment, "body" => "@Claude, a look?"}
           } = item

    # Not its author's, who mentioned themself.
    assert {:ok, []} = Inbox.items(@instance, grace)

    {:ok, %{comment: reply}} =
      Comments.reply(@instance, room, ken(), thread, "And mine", mentions: [key])

    assert {:ok, [%{"data" => %{"comment" => ^reply}}, %{"data" => %{"comment" => ^comment}}]} =
             items(claude, 2)

    :ok = Inbox.mark_read(@instance, claude, [item["id"]])
    assert {:ok, [%{"data" => %{"comment" => ^reply}}]} = Inbox.items(@instance, claude)
    assert {:ok, [_, %{"read" => true}]} = Inbox.items(@instance, claude, all: true)

    :ok = Inbox.mark_read(@instance, claude, :all)
    assert {:ok, []} = Inbox.items(@instance, claude)
  end

  test "an edit that mentions someone is not in their inbox", %{
    room: room,
    claude: claude,
    key: key
  } do
    {:ok, %{thread: thread, comment: comment}} = Comments.start(@instance, room, ada(), nil, "Hm")
    {:ok, _} = Comments.edit(@instance, room, ada(), thread, comment, "@Claude?", mentions: [key])
    {:ok, _} = Comments.start(@instance, room, ada(), nil, "Now", mentions: [key])

    assert {:ok, [%{"data" => %{"body" => "Now"}}]} = items(claude)
  end

  test "an app's own event that mentions someone", %{room: room, claude: claude, key: key} do
    :ok =
      Issho.Events.emit(@instance, room, "retro.assigned",
        by: ada(),
        data: %{card: "c1", mentions: [key]}
      )

    assert {:ok, [%{"name" => "retro.assigned", "data" => %{"card" => "c1"}}]} = items(claude)
  end

  test "only the rooms its reader may still read", %{room: room, claude: claude, key: key} do
    {:ok, _} = Comments.start(@instance, room, ada(), nil, "@Claude", mentions: [key])
    assert {:ok, [_]} = items(claude)

    IsshoTest.Policy.deny(key)
    on_exit(fn -> IsshoTest.Policy.allow(key) end)
    assert {:ok, []} = Inbox.items(@instance, claude)
  end

  test "no one opens an inbox in a room", %{key: key} do
    {:ok, ken} = Issho.join_as(@instance, ken(), "issho.inbox")
    assert {:error, :forbidden} = Participant.open(ken, Inbox.document(key))
  end

  test "the app's :on_mention wakes whom a comment mentions", %{room: room, key: key} do
    test = self()
    config = Config.get(@instance)
    :ok = Config.put(%{config | on_mention: fn who, item -> send(test, {:woken, who, item}) end})
    on_exit(fn -> Config.put(config) end)

    {:ok, %{comment: comment}} =
      Comments.start(@instance, room, ada(), nil, "@Claude", mentions: [key])

    assert_receive {:woken, ^key, %{"data" => %{"comment" => ^comment}, "read" => false}}, 1_000
  end

  describe "the inbox tool" do
    test "gives what was said while away, then it is read", %{
      room: room,
      claude: claude,
      key: key
    } do
      {:ok, %{thread: thread}} =
        Comments.start(@instance, room, ada(), nil, "@Claude, a look?", mentions: [key])

      {:ok, [_]} = items(claude)
      ctx = Tool.Context.new(@instance, claude, on_behalf_of: ada())

      assert {:ok, %{"items" => [item]}} =
               Tools.call(Tools.room(), "inbox", %{"keep_unread" => true}, ctx)

      assert %{"room" => ^room, "thread" => ^thread, "body" => "@Claude, a look?", "by" => "Ada"} =
               item

      assert {:ok, %{"items" => [_]}} = Tools.call(Tools.room(), "inbox", %{}, ctx)
      assert {:ok, %{"items" => []}} = Tools.call(Tools.room(), "inbox", %{}, ctx)

      assert {:ok, %{"items" => [%{"read" => true}]}} =
               Tools.call(Tools.room(), "inbox", %{"all" => true}, ctx)
    end

    test "what the agent heard in the room is read", %{room: room, claude: claude, key: key} do
      ctx = Tool.Context.new(@instance, claude)
      {:ok, _} = Tools.call(Tools.room(), "join_room", %{"room" => room}, ctx)
      {:ok, _} = Comments.start(@instance, room, ada(), nil, "@Claude", mentions: [key])
      {:ok, [_]} = items(claude)

      assert {:ok, %{"events" => [_]}} =
               Tools.call(
                 Tools.room(),
                 "wait_for_events",
                 %{"room" => room, "mentions_me" => true, "names" => ["comment.created"]},
                 ctx
               )

      assert {:ok, []} = Inbox.items(@instance, claude)
    end
  end

  describe "over MCP" do
    setup do
      Application.put_env(:issho, Issho.MCP, instance: @instance)
      on_exit(fn -> Application.delete_env(:issho, Issho.MCP) end)
    end

    test "the resource, its change, and the server's instructions", %{room: room} do
      client =
        connect(IsshoTest.MCP, scope: ada(), client_info: %{"name" => "claude-code"})

      key = "agent:claude-code:user:ada"
      {:ok, _} = call_tool(client, "look_around", %{"room" => room})
      # Shared: the inbox tells of it from a process of its own.
      listen(IsshoTest.MCP, shared: true)

      {:ok, _} = Comments.start(@instance, room, ken(), nil, "@Claude Code?", mentions: [key])
      {:ok, [_]} = items(%{id: key, name: "Claude Code", kind: :agent})
      assert_resource_updated("issho://inbox")

      assert {:ok, read} = read_resource(client, "issho://inbox")
      assert inspect(read) =~ "@Claude Code?"

      assert IsshoTest.MCP.__sake__(:instructions) =~ "call the\ninbox tool"
    end
  end
end
