defmodule Issho.IfRevisionTest do
  # A change made on what its author saw (if_revision): applied while the
  # document is still that version, refused as stale when anyone changed
  # it since, before its operations or its hook run; a retry gets its
  # receipt; a change without the condition merges as it always has.
  use ExUnit.Case, async: false

  alias Issho.{Authority, Documents, Tool, Tools, Transaction, Version}

  doctest Issho.Version

  @instance IsshoTest.Issho

  defp set(key, value), do: %{"op" => "set", "path" => [key], "value" => value}

  setup do
    test = self()
    id = "canvas:" <> Transaction.id()

    hook = fn ops, _context ->
      send(test, {:hook, ops})
      :ok
    end

    spec = %{engine: Issho.Engine.Map, initial: %{}, store: :none, on_transaction: hook}
    {:ok, pid} = Documents.open(@instance, id, nil, spec: spec)
    %{pid: pid}
  end

  defp version(pid) do
    {:ok, snapshot} = Authority.snapshot(pid)
    Version.of(snapshot)
  end

  defp commit(pid, ops, opts) do
    {:ok, transaction} = Transaction.new(pid, ops, opts)
    Authority.commit(pid, transaction, Keyword.get(opts, :author, "agent:claude"))
  end

  test "on the version it saw, it applies; its receipt says the version now", %{pid: pid} do
    seen = version(pid)

    assert {:ok, %{"revision" => 1, "version" => now}} =
             commit(pid, [set("a", 1)], if_revision: seen)

    assert now == version(pid)
    assert_received {:hook, _}
  end

  test "changed since, it is refused before its operations or its hook run", %{pid: pid} do
    seen = version(pid)
    {:ok, _} = commit(pid, [set("title", "Ada's")], author: "user:ada")
    {:ok, _} = commit(pid, [set("title", "Ken's")], author: "user:ken")
    assert_received {:hook, _}
    assert_received {:hook, _}

    assert {:error, {:stale, stale}} = commit(pid, [set("title", "Mine")], if_revision: seen)

    assert %{
             "version" => version,
             "revision" => 2,
             "count" => 2,
             "complete" => true,
             "changes" => [
               %{"revision" => 1, "author" => "user:ada"},
               %{"revision" => 2, "author" => "user:ken"}
             ]
           } = stale

    assert version == version(pid)
    refute_received {:hook, _}
    assert {:ok, %{"state" => %{"title" => "Ken's"}}} = Authority.snapshot(pid)

    # Read again, it applies.
    assert {:ok, _} = commit(pid, [set("title", "Mine")], if_revision: version)
  end

  test "a version of another epoch is stale, and says it no longer knows what changed", %{
    pid: pid
  } do
    assert {:error, {:stale, %{"count" => nil, "changes" => [], "complete" => false}}} =
             commit(pid, [set("a", 1)], if_revision: "another-epoch:0")

    refute_received {:hook, _}
  end

  test "the latest 20 changes, and how many", %{pid: pid} do
    seen = version(pid)
    for i <- 1..25, do: {:ok, _} = commit(pid, [set("n", i)], author: "user:ada")

    assert {:error, {:stale, %{"count" => 25, "changes" => changes, "complete" => false}}} =
             commit(pid, [set("a", 1)], if_revision: seen)

    assert length(changes) == 20
    assert List.last(changes)["revision"] == 25
  end

  test "a retry gets its receipt though the document went on; its id with another condition is refused",
       %{pid: pid} do
    {:ok, transaction} = Transaction.new(pid, [set("a", 1)], if_revision: version(pid))
    assert {:ok, %{"revision" => 1}} = Authority.commit(pid, transaction, "agent:claude")
    {:ok, _} = commit(pid, [set("b", 2)], author: "user:ada")

    assert {:ok, %{"revision" => 1, "duplicate" => true}} =
             Authority.commit(pid, transaction, "agent:claude")

    # The same id, without the condition: another transaction.
    unconditional = Map.delete(transaction, "if_revision")
    assert {:error, :id_reused} = Authority.commit(pid, unconditional, "agent:claude")
  end

  test "without the condition, an older revision merges as before", %{pid: pid} do
    {:ok, old} = Transaction.new(pid, [set("a", 1)])
    {:ok, _} = commit(pid, [set("b", 2)], author: "user:ada")

    assert {:ok, %{"revision" => 2}} = Authority.commit(pid, old, "agent:claude")
    assert {:ok, %{"state" => %{"a" => 1, "b" => 2}}} = Authority.snapshot(pid)
  end

  test "a condition that is not the revision it was made on is refused", %{pid: pid} do
    {:ok, transaction} = Transaction.new(pid, [set("a", 1)], if_revision: version(pid))

    assert {:error, :invalid_if_revision} =
             Authority.commit(pid, %{transaction | "if_revision" => 7}, "agent:claude")

    assert {:error, :invalid_version} = Transaction.new(pid, [set("a", 1)], if_revision: "41")
  end

  describe "the tools" do
    setup do
      room = "board:" <> Transaction.id()
      ctx = Tool.Context.new(@instance, %{id: "agent:claude", name: "Claude", kind: :agent})
      %{room: room, ctx: ctx}
    end

    test "read_document gives the version; a change on it applies, on an older one is refused",
         %{room: room, ctx: ctx} do
      {:ok, %{"version" => seen}} =
        Tools.call(Tools.room(), "read_document", %{"room" => room}, ctx)

      assert {:ok, %{"version" => now}} =
               Tools.call(
                 Tools.room(),
                 "update_state",
                 %{"room" => room, "ops" => [set("title", "Q3")], "if_revision" => seen},
                 ctx
               )

      {:ok, _} =
        Issho.transact(@instance, room, [set("title", "Q4")],
          author: %{id: "user:ada", name: "Ada"}
        )

      assert {:error, message} =
               Tools.call(
                 Tools.room(),
                 "change_document",
                 %{"room" => room, "ops" => [set("title", "Q3!")], "if_revision" => now},
                 ctx
               )

      assert message =~ "no longer the version you read"
      assert message =~ "1 change since, by user:ada"

      {:ok, %{"version" => latest, "state" => %{"title" => "Q4"}}} =
        Tools.call(Tools.room(), "read_document", %{"room" => room}, ctx)

      assert message =~ latest

      # Without it, as before.
      assert {:ok, _} =
               Tools.call(
                 Tools.room(),
                 "update_state",
                 %{"room" => room, "ops" => [set("x", 1)]},
                 ctx
               )
    end
  end
end
