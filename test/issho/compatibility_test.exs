defmodule Issho.CompatibilityTest do
  # What this Issho saves, Issho 0.5.0 loads, commits to and rebuilds
  # revisions of, whatever the options: a document folded to its
  # :journal, compacted, reopened from a journal too long,
  # or kept whole. V050 below is 0.5.0's own reading of a stored
  # document, line for line from its lib/issho/authority.ex (v0.5.0); the
  # tests run it over documents this code saved, then load what it
  # committed back here.
  use ExUnit.Case, async: true

  alias Issho.{Authority, Documents, Engine, Store, Transaction}

  defmodule V050 do
    @moduledoc false
    # Issho 0.5.0's authority, reduced to what it does with a stored
    # document. Each function names the lines of v0.5.0's
    # lib/issho/authority.ex it follows.

    # :158, a stored document of the engine's name and version is
    # used as it is.
    def load(document, engine) do
      if document["engine"] == engine.name() and document["engine_version"] == engine.version(),
        do: {:ok, document},
        else: {:error, :engine_mismatch}
    end

    # :486-500 and :503-508, content_at/3 of a revision before the latest:
    # "base" with 0 for a default, the first revision - base events, each
    # applied with its author from "initial".
    def content_at(document, engine, epoch, revision) do
      base = Map.get(document, "base", 0)

      if epoch == document["epoch"] and is_integer(revision) and revision >= base and
           revision <= document["revision"] do
        events = Enum.take(document["journal"], revision - base)

        with {:ok, state} <- replay(engine, document["initial"], events),
             do: Engine.validate(engine, state, [])
      else
        {:error, :unknown_revision}
      end
    end

    defp replay(_engine, state, []), do: {:ok, state}

    defp replay(engine, state, [event | rest]) do
      with {:ok, next} <- engine.apply(state, event["ops"], author: event["author"]),
           do: replay(engine, next, rest)
    end

    # :280-298, a commit: the event appended to "journal" with
    # Map.update!/3 (a document without one raises), its receipt added,
    # nothing else touched.
    def commit(document, engine, transaction, author) do
      {:ok, state} = engine.apply(document["state"], transaction["ops"], author: author)
      revision = document["revision"] + 1

      event =
        transaction
        |> Map.take(["id", "epoch", "base_revision", "ops"])
        |> Map.merge(%{"revision" => revision, "author" => author})

      document
      |> Map.merge(%{"state" => state, "revision" => revision})
      |> Map.update!("journal", &(&1 ++ [event]))
      |> put_in(["receipts", transaction["id"]], %{
        "digest" => Transaction.digest(transaction, author),
        "revision" => revision,
        "author" => author
      })
    end

    # :409-413, the changes a stale transaction made on revision `seen`
    # is told of.
    def since(document, seen) do
      base = Map.get(document, "base", 0)
      if seen >= base, do: Enum.drop(document["journal"], seen - base)
    end
  end

  defmodule Compacting do
    @moduledoc false
    # The map engine, whose "trash" key only its past needs: its content
    # is the map without it, and compact/2 drops it.
    @behaviour Issho.Engine
    alias Issho.Engine.Map, as: MapEngine

    def name, do: "compacting"
    def version, do: 1
    defdelegate init(initial, opts), to: MapEngine
    defdelegate apply(state, ops, opts), to: MapEngine
    def validate(state, _opts), do: {:ok, Map.delete(state, "trash")}
    def compact(state, _opts), do: {:ok, Map.delete(state, "trash")}
  end

  defmodule Policy do
    @moduledoc false
    @behaviour Issho.Policy
    @impl true
    def authorize(_identity, _room, _action), do: :ok
    @impl true
    def document(_identity, _id), do: {:ok, %{engine: Compacting, initial: %{}}}
  end

  @ttl 10

  setup do
    pubsub = :"Issho.CompatibilityTest.PubSub#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    start = fn opts ->
      Issho.Test.start!([policy: Policy, pubsub: pubsub, ttl: @ttl] ++ opts)
    end

    %{
      bounded: start.(history: 20, journal: 8, compact: true),
      unbounded: start.([])
    }
  end

  defp store(instance), do: Module.concat(instance, "Store")

  defp open(instance, id) do
    {:ok, pid} = Documents.open(instance, id)
    {:ok, _snapshot, _engine} = Authority.join(pid, self())
    pid
  end

  defp close(instance, id, pid) do
    ref = Process.monitor(pid)
    Authority.leave(pid, self())
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000
    await_gone(instance, id, pid)
  end

  defp await_gone(instance, id, pid) do
    if Documents.whereis(instance, id) == pid do
      Process.sleep(1)
      await_gone(instance, id, pid)
    end
  end

  defp tx(epoch, revision, n),
    do: %{
      "id" => Transaction.id(),
      "epoch" => epoch,
      "base_revision" => revision,
      "ops" => [%{"op" => "set", "path" => ["n"], "value" => n}]
    }

  defp commit_n(pid, range) do
    for n <- range do
      {:ok, %{"epoch" => epoch, "revision" => revision}} = Authority.snapshot(pid)
      {:ok, _} = Authority.commit(pid, tx(epoch, revision, n), "user:ada")
    end

    :ok
  end

  defp trash(pid) do
    {:ok, %{"epoch" => epoch, "revision" => revision}} = Authority.snapshot(pid)
    big = %{"op" => "set", "path" => ["trash"], "value" => String.duplicate("x", 100_000)}
    {:ok, _} = Authority.commit(pid, %{tx(epoch, revision, 0) | "ops" => [big]}, "user:ada")
  end

  defp stored(instance, id) do
    {:ok, document} = Store.Memory.load(store(instance), id)
    document
  end

  # 0.5.0 loads the stored document, rebuilds each revision it holds as
  # this code does, tells a stale transaction as many changes as happened,
  # and commits to it; this code then loads what 0.5.0 saved, with the
  # revision 0.5.0 made.
  defp assert_050_reads(instance, id, pid) do
    document = stored(instance, id)
    content = Store.Memory.content(store(instance), id)
    assert {:ok, ^document} = V050.load(document, Compacting)

    %{"epoch" => epoch, "revision" => revision} = document
    base = Map.get(document, "base", 0)
    assert {:ok, ^content} = V050.content_at(document, Compacting, epoch, revision)

    for seen <- base..revision//1 do
      assert V050.content_at(document, Compacting, epoch, seen) ==
               Authority.content_at(pid, epoch, seen)

      assert length(V050.since(document, seen)) == revision - seen
    end

    close(instance, id, pid)
    committed = V050.commit(document, Compacting, tx(epoch, revision, "0.5.0"), "user:ken")
    {:ok, after_commit} = Engine.validate(Compacting, committed["state"], [])
    assert after_commit == Map.put(content, "n", "0.5.0")
    assert {:ok, ^after_commit} = V050.content_at(committed, Compacting, epoch, revision + 1)
    :ok = Store.Memory.save(store(instance), id, {epoch, revision}, committed, after_commit)

    pid = open(instance, id)
    next = revision + 1

    assert {:ok, %{"epoch" => ^epoch, "revision" => ^next, "content" => ^after_commit}} =
             Authority.content(pid)

    pid
  end

  test "a document whose journal folded to :journal", %{bounded: instance} do
    id = "doc:" <> Transaction.id()
    pid = open(instance, id)
    commit_n(pid, 1..50)
    assert stored(instance, id)["base"] > 0

    pid = assert_050_reads(instance, id, pid)
    commit_n(pid, 51..60)
    assert_050_reads(instance, id, pid)
  end

  test "a compacted document, before and after its next transactions", %{bounded: instance} do
    id = "doc:" <> Transaction.id()
    pid = open(instance, id)
    commit_n(pid, 1..5)
    trash(pid)
    close(instance, id, pid)
    assert %{"continues" => _epoch, "journal" => []} = stored(instance, id)

    pid = open(instance, id)
    pid = assert_050_reads(instance, id, pid)
    commit_n(pid, 6..20)
    assert_050_reads(instance, id, pid)
  end

  test "a document saved with a journal too long, once this code commits to it",
       %{bounded: instance} do
    long = "doc:" <> Transaction.id()
    pid = open(instance, long)
    {:ok, %{"epoch" => epoch}} = Authority.snapshot(pid)
    close(instance, long, pid)

    # As 0.5.0 saved it, before :journal: every transaction since revision 0.
    created = Map.drop(stored(instance, long), ["base", "horizon"])

    document =
      Enum.reduce(1..40, created, fn n, document ->
        V050.commit(document, Compacting, tx(epoch, n - 1, n), "user:ada")
      end)

    :ok = Store.Memory.save(store(instance), long, {epoch, 0}, document, %{"n" => 40})

    pid = open(instance, long)
    commit_n(pid, 41..42)
    assert_050_reads(instance, long, pid)
  end

  test "a document kept whole, without :history or :journal", %{unbounded: instance} do
    id = "doc:" <> Transaction.id()
    pid = open(instance, id)
    commit_n(pid, 1..30)
    assert %{"base" => 0, "journal" => journal} = stored(instance, id)
    assert length(journal) == 30
    assert_050_reads(instance, id, pid)
  end
end
