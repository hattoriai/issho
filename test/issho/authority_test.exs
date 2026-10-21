defmodule Issho.AuthorityTest do
  use ExUnit.Case, async: false

  alias Issho.{Authority, Documents, Store, Transaction}

  @instance IsshoTest.Issho

  setup do
    id = "board:" <> Transaction.id()
    {:ok, pid} = Documents.open(@instance, id)
    {:ok, snapshot, IsshoTest.Binding} = Authority.join(pid, self())
    Phoenix.PubSub.subscribe(IsshoTest.PubSub, Authority.topic(id))
    %{id: id, pid: pid, snapshot: snapshot}
  end

  defp tx(snapshot, ops, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, Transaction.id()),
      "epoch" => snapshot["epoch"],
      "base_revision" => Keyword.get(opts, :base, snapshot["revision"]),
      "ops" => ops
    }
  end

  defp set(key, value), do: %{"op" => "set", "path" => [key], "value" => value}

  test "a new document starts from the policy's initial content, saved", %{
    id: id,
    snapshot: snapshot
  } do
    assert snapshot["revision"] == 0
    assert snapshot["state"] == %{"title" => "Untitled", "doc" => id}
    assert {:ok, %{"revision" => 0}} = Store.Memory.load(IsshoTest.Store, id)
  end

  test "commits in order, saves, then broadcasts", %{id: id, pid: pid, snapshot: snapshot} do
    t = tx(snapshot, [set("title", "Plan")])
    assert {:ok, %{"id" => tx_id, "revision" => 1}} = Authority.commit(pid, t, "user:1")
    assert tx_id == t["id"]

    assert_receive {Issho, :transaction, ^id,
                    %{"revision" => 1, "author" => "user:1", "ops" => ops}}

    assert ops == t["ops"]

    assert %{"title" => "Plan"} = Store.Memory.content(IsshoTest.Store, id)
  end

  test "a retry is applied once, and a reused id is refused", %{pid: pid, snapshot: snapshot} do
    t = tx(snapshot, [%{"op" => "increment", "path" => ["n"], "by" => 1}])
    assert {:ok, %{"revision" => 1}} = Authority.commit(pid, t, "user:1")
    assert {:ok, %{"revision" => 1, "duplicate" => true}} = Authority.commit(pid, t, "user:1")

    assert {:error, :id_reused} =
             Authority.commit(pid, %{t | "ops" => [set("n", 9)]}, "user:1")

    assert {:error, :id_reused} = Authority.commit(pid, t, "user:2")
    assert {:ok, %{"state" => %{"n" => 1}, "revision" => 1}} = Authority.snapshot(pid)
  end

  test "refuses a wrong epoch, a future base and bad operations, changing nothing",
       %{pid: pid, snapshot: snapshot} do
    assert {:error, :epoch_mismatch} =
             Authority.commit(pid, %{tx(snapshot, [set("a", 1)]) | "epoch" => "other"}, "u")

    assert {:error, :invalid_base_revision} =
             Authority.commit(pid, tx(snapshot, [set("a", 1)], base: 5), "u")

    assert {:error, :invalid_operations} = Authority.commit(pid, tx(snapshot, []), "u")

    assert {:error, :invalid_path} =
             Authority.commit(
               pid,
               tx(snapshot, [set("a", 1), %{"op" => "set", "path" => [], "value" => 1}]),
               "u"
             )

    assert {:error, :invalid_transaction} = Authority.commit(pid, %{"ops" => []}, "u")
    assert {:ok, %{"revision" => 0}} = Authority.snapshot(pid)
  end

  test "reads any accepted revision of the epoch", %{pid: pid, snapshot: snapshot} do
    {:ok, _} = Authority.commit(pid, tx(snapshot, [set("title", "One")]), "u")
    {:ok, _} = Authority.commit(pid, tx(snapshot, [set("title", "Two")], base: 1), "u")

    assert {:ok, %{"title" => "One"}} = Authority.content_at(pid, snapshot["epoch"], 1)
    assert {:ok, %{"title" => "Two"}} = Authority.content_at(pid, snapshot["epoch"], 2)
    assert {:ok, %{"title" => "Untitled"}} = Authority.content_at(pid, snapshot["epoch"], 0)
    assert {:error, :unknown_revision} = Authority.content_at(pid, snapshot["epoch"], 3)
    assert {:error, :unknown_revision} = Authority.content_at(pid, "other", 1)
  end

  test "tells a reconnecting author which of its transactions were accepted",
       %{pid: pid, snapshot: snapshot} do
    t = tx(snapshot, [set("a", 1)])
    {:ok, _} = Authority.commit(pid, t, "user:1")
    assert Authority.accepted(pid, [t["id"], "never-sent"], "user:1") == [t["id"]]
    assert Authority.accepted(pid, [t["id"]], "user:2") == []
  end

  test "stops when unused, and the next open loads the saved document", %{
    id: id,
    pid: pid,
    snapshot: snapshot
  } do
    {:ok, _} = Authority.commit(pid, tx(snapshot, [set("title", "Kept")]), "u")
    ref = Process.monitor(pid)
    # The test process is the only member: tell the authority it left.
    send(pid, {:DOWN, make_ref(), :process, self(), :normal})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    {:ok, again} = Documents.open(@instance, id)
    assert again != pid

    assert {:ok, %{"state" => %{"title" => "Kept"}, "revision" => 1, "epoch" => epoch}} =
             Authority.snapshot(again)

    assert epoch == snapshot["epoch"]
  end

  @tag :capture_log
  test "an authority that finds a newer save elsewhere stops", %{
    id: id,
    pid: pid,
    snapshot: snapshot
  } do
    {:ok, doc} = Store.Memory.load(IsshoTest.Store, id)
    :ok = Store.Memory.save(IsshoTest.Store, id, {doc["epoch"], 0}, %{doc | "revision" => 7}, %{})

    ref = Process.monitor(pid)
    assert {:error, :stale_authority} = Authority.commit(pid, tx(snapshot, [set("a", 1)]), "u")
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "a document the policy does not know does not open" do
    assert {:error, :not_found} = Documents.open(@instance, "missing:1")
  end
end
