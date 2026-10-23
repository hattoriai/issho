defmodule Issho.StreamsTest do
  # Streams of a room: written a piece at a time, seen as they come by
  # whom they are for, picked up where they got to, and kept for a while.
  use ExUnit.Case, async: false

  alias Issho.{Config, Event, Events, Stream, Streams, Tool, Tools, Transaction}

  @instance IsshoTest.Issho

  setup do
    room = "board:" <> Transaction.id()
    :ok = Events.subscribe(@instance, room)
    %{room: room}
  end

  defp ada, do: %{id: "user:ada", name: "Ada"}
  defp ken, do: %{id: "user:ken", name: "Ken"}
  defp claude, do: %{id: "agent:claude", name: "Claude", kind: :agent}

  # Claude, at work for Ada.
  defp claude_for_ada, do: Issho.Identity.new(claude(), on_behalf_of: ada())

  defp chunks(id, acc \\ []) do
    receive do
      {Issho, :stream, ^id, {:chunk, data}} -> chunks(id, [data | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  test "written a piece at a time, seen as it comes, finished", %{room: room} do
    {:ok, stream} = Streams.start(@instance, room, kind: "summary", for: ada(), by: claude())
    id = stream.id

    assert %Stream{state: :writing, for: "user:ada", kind: "summary", content: ""} = stream

    assert_receive {Issho, :event,
                    %Event{
                      name: "stream.started",
                      data: %{stream: ^id, kind: "summary", for: "user:ada"}
                    }}

    assert {:ok, %Stream{content: ""}} = Streams.subscribe(@instance, id, ada())
    :ok = Streams.append(stream, "## Summary\n\n")
    :ok = Streams.append(stream, ["The plan ", "holds."])
    :ok = Streams.finish(stream)

    assert chunks(id) == ["## Summary\n\n", "The plan holds."]
    assert_receive {Issho, :stream, ^id, :finished}

    assert_receive {Issho, :event,
                    %Event{name: "stream.finished", data: %{stream: ^id, size: 27}}}

    assert {:ok, %Stream{state: :finished, content: "## Summary\n\nThe plan holds.", size: 27}} =
             Streams.get(@instance, id)

    assert {:error, :not_writing} = Streams.append(stream, "more")
  end

  test "one who comes in the middle gets what was written, then what comes, once", %{room: room} do
    {:ok, stream} = Streams.start(@instance, room, kind: "report", for: :room)
    :ok = Streams.append(stream, "First. ")
    :ok = Streams.append(stream, "Second. ")

    assert {:ok, %Stream{content: "First. Second. "}} =
             Streams.subscribe(@instance, stream.id, ken())

    :ok = Streams.append(stream, "Third.")
    assert chunks(stream.id) == ["Third."]
  end

  test "for a person: them, their agents and its writer; no one else", %{room: room} do
    {:ok, stream} = Streams.start(@instance, room, kind: "draft", for: "user:ada", by: claude())

    assert {:ok, _} = Streams.subscribe(@instance, stream.id, ada())
    assert {:ok, _} = Streams.subscribe(@instance, stream.id, claude_for_ada())
    assert {:ok, _} = Streams.subscribe(@instance, stream.id, claude())
    assert {:error, :forbidden} = Streams.subscribe(@instance, stream.id, ken())

    {:ok, public} = Streams.start(@instance, room, kind: "report", for: :room)

    assert Enum.map(Streams.list(@instance, room, ken()), & &1.id) == [public.id]

    assert Enum.map(Streams.list(@instance, room, ada()), & &1.id) == [stream.id, public.id]
  end

  test "only those who may read the room; :policy asks :read_stream", %{room: room} do
    {:ok, public} = Streams.start(@instance, room, kind: "report", for: :room)
    {:ok, chosen} = Streams.start(@instance, room, kind: "report", for: :policy)

    IsshoTest.Policy.deny("user:ken")
    on_exit(fn -> IsshoTest.Policy.allow("user:ken") end)
    assert {:error, :forbidden} = Streams.subscribe(@instance, public.id, ken())
    IsshoTest.Policy.allow("user:ken")

    assert {:ok, _} = Streams.subscribe(@instance, chosen.id, ken())
    IsshoTest.Policy.deny_action(:read_stream)
    on_exit(fn -> IsshoTest.Policy.allow_action(:read_stream) end)
    assert {:error, :forbidden} = Streams.subscribe(@instance, chosen.id, ken())
    assert {:ok, _} = Streams.subscribe(@instance, public.id, ken())
  end

  test "its writer goes: it fails, or finishes when told", %{room: room} do
    test = self()

    {writer, ref} =
      spawn_monitor(fn ->
        {:ok, stream} = Streams.start(@instance, room, kind: "log", for: :room)
        :ok = Streams.append(stream, "Half")
        send(test, {:started, stream})
      end)

    assert_receive {:started, stream}
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}

    assert_receive {Issho, :event,
                    %Event{name: "stream.failed", data: %{reason: "writer_exited"}}}

    assert {:ok, %Stream{state: :failed, outcome: "writer_exited", content: "Half"}} =
             Streams.get(@instance, stream.id)

    task =
      Task.async(fn ->
        {:ok, stream} = Streams.start(@instance, room, kind: "log", for: :room, on_exit: :finish)
        stream
      end)

    stream = Task.await(task)
    assert_receive {Issho, :event, %Event{name: "stream.finished", data: %{stream: id}}}
    assert id == stream.id
  end

  test "kept for a while after, then gone; closed, gone at once", %{room: room} do
    {:ok, stream} = Streams.start(@instance, room, kind: "summary", for: :room, keep: 50)
    {:ok, _} = Streams.subscribe(@instance, stream.id, ada())
    :ok = Streams.finish(stream)
    assert_receive {Issho, :stream, id, :gone}, 1_000
    assert id == stream.id
    assert {:error, :not_found} = Streams.get(@instance, stream.id)

    {:ok, draft} = Streams.start(@instance, room, kind: "draft", for: ada())
    {:ok, _} = Streams.subscribe(@instance, draft.id, ada())
    :ok = Streams.append(draft, "Take this")
    :ok = Streams.close(draft, :accepted)

    assert_receive {Issho, :stream, draft_id, {:closed, "accepted"}}
    assert draft_id == draft.id

    assert_receive {Issho, :event,
                    %Event{name: "stream.closed", data: %{outcome: "accepted", was: "writing"}}}

    assert {:error, :not_found} = Streams.get(@instance, draft.id)
  end

  test "its limits: a stream's size, a room's streams", %{room: room} do
    config = Config.get(@instance)
    :ok = Config.put(%{config | stream_max_bytes: 10, room_max_streams: 2})
    on_exit(fn -> Config.put(config) end)

    {:ok, stream} = Streams.start(@instance, room, kind: "log", for: :room)
    :ok = Streams.append(stream, "12345")
    assert {:error, :too_large} = Streams.append(stream, "678901")

    assert {:ok, %Stream{state: :failed, outcome: "too_large", content: "12345"}} =
             Streams.get(@instance, stream.id)

    {:ok, _} = Streams.start(@instance, room, kind: "log", for: :room)
    assert {:error, :too_many_streams} = Streams.start(@instance, room, kind: "log", for: :room)
    assert {:error, :no_reader} = Streams.start(@instance, "board:other", kind: "log")
  end

  test "a watcher hears of the room's new streams", %{room: room} do
    {:ok, before} = Streams.start(@instance, room, kind: "report", for: :room)
    :ok = Streams.append(before, "So far")

    assert {:ok, [%Stream{content: "So far"}]} = Streams.watch(@instance, room, ken())

    {:ok, stream} = Streams.start(@instance, room, kind: "draft", for: :room)
    assert_receive {Issho, :stream_started, ^room, %Stream{id: id}}
    assert id == stream.id
  end

  describe "agents" do
    setup do
      %{ctx: Tool.Context.new(@instance, claude(), on_behalf_of: ada()), tools: Tools.room()}
    end

    test "an agent writes a stream for the person it works for", %{
      ctx: ctx,
      tools: tools,
      room: room
    } do
      assert {:ok, %{"stream" => id}} =
               Tools.call(tools, "start_stream", %{"room" => room, "kind" => "summary"}, ctx)

      assert {:ok, %Stream{for: "user:ada", by: %{key: "agent:claude"}}} =
               Streams.subscribe(@instance, id, ada())

      assert {:ok, "Added."} =
               Tools.call(tools, "append_to_stream", %{"stream" => id, "text" => "Done."}, ctx)

      assert_receive {Issho, :stream, ^id, {:chunk, "Done."}}

      other = Tool.Context.new(@instance, %{id: "agent:other", name: "Other", kind: :agent})

      assert {:error, "That stream is not yours."} =
               Tools.call(tools, "append_to_stream", %{"stream" => id, "text" => "Mine"}, other)

      assert {:ok, "Finished."} = Tools.call(tools, "finish_stream", %{"stream" => id}, ctx)
      assert_receive {Issho, :stream, ^id, :finished}
    end

    test "it lives while the agent is in the room", %{ctx: ctx, tools: tools, room: room} do
      {:ok, %{"stream" => id}} =
        Tools.call(
          tools,
          "start_stream",
          %{"room" => room, "kind" => "report", "for" => "room"},
          ctx
        )

      {:ok, _} = Tools.call(tools, "leave_room", %{"room" => room}, ctx)

      assert_receive {Issho, :event,
                      %Event{name: "stream.failed", data: %{stream: ^id, reason: "writer_exited"}}},
                     1_000
    end
  end

  @tag :cluster
  test "read on another node, as it comes", %{room: room} do
    # (Sake warns, rightly, that its state is kept on each node.)
    {{_peer, node}, _log} = ExUnit.CaptureLog.with_log(&IsshoTest.Cluster.start/0)

    {:ok, stream} = Streams.start(@instance, room, kind: "summary", for: ada())
    :ok = Streams.append(stream, "Here ")

    assert {_pid, {:ok, %Stream{content: "Here "}}} =
             :erpc.call(node, IsshoTest.Cluster, :subscribe, [stream.id, ada(), self()])

    assert {_pid, {:error, :forbidden}} =
             :erpc.call(node, IsshoTest.Cluster, :subscribe, [stream.id, ken(), self()])

    :ok = Streams.append(stream, "and there.")
    assert_receive {:peer, {Issho, :stream, id, {:chunk, "and there."}}}, 2_000
    assert id == stream.id

    # The room's streams, listed from the other node.
    assert [%Stream{id: ^id}] = :erpc.call(node, Streams, :list, [@instance, room, ada()])
  end
end
