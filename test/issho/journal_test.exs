defmodule Issho.JournalTest do
  # A document keeps the journal of its epoch as Issho 0.5.0 stores it: the
  # state at revision "base" ("initial") and each accepted transaction
  # since. With :journal, it keeps the latest :journal of them; the older
  # fold into "initial", so the stored document stays bounded.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Issho.{Authority, Documents, Store, Transaction}

  defmodule Policy do
    @moduledoc false
    @behaviour Issho.Policy
    @impl true
    def authorize(_identity, _room, _action), do: :ok
    @impl true
    def document(_identity, _id), do: {:error, :not_found}
  end

  defmodule ObservedEngine do
    @moduledoc false
    # The map engine, telling its :observer each time it applies a
    # transaction's operations; an operation "raise" raises.
    @behaviour Issho.Engine
    alias Issho.Engine.Map, as: MapEngine

    def name, do: "observed"
    def version, do: 1
    defdelegate init(initial, opts), to: MapEngine

    def apply(state, ops, opts) do
      send(Keyword.fetch!(opts, :observer), :applied)
      if %{"op" => "raise"} in ops, do: raise("cannot apply")
      MapEngine.apply(state, ops, opts)
    end
  end

  setup do
    pubsub = :"Issho.JournalTest.PubSub#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    %{
      capped: Issho.Test.start!(policy: Policy, pubsub: pubsub, journal: 8),
      unbounded: Issho.Test.start!(policy: Policy, pubsub: pubsub)
    }
  end

  defp store_of(instance), do: Module.concat(instance, "Store")

  defp open(instance, opts \\ []) do
    id = Keyword.get(opts, :id, "canvas:" <> Transaction.id())
    store = Keyword.get(opts, :store, {Store.Memory, store_of(instance)})
    spec = %{engine: ObservedEngine, opts: [observer: self()], store: store}
    {:ok, pid} = Documents.open(instance, id, nil, spec: spec)
    {id, pid}
  end

  defp set_n(pid, n) do
    {:ok, %{"epoch" => epoch, "revision" => revision}} = Authority.snapshot(pid)

    %{
      "id" => Transaction.id(),
      "epoch" => epoch,
      "base_revision" => revision,
      "ops" => [%{"op" => "set", "path" => ["n"], "value" => n}]
    }
  end

  defp commit_n(pid, range) do
    for n <- range, do: {:ok, %{"revision" => ^n}} = Authority.commit(pid, set_n(pid, n), "u")
    :ok
  end

  # How many times the engine applied operations since last asked.
  defp applies(count \\ 0) do
    receive do
      :applied -> applies(count + 1)
    after
      0 -> count
    end
  end

  defp stored(instance, id) do
    {:ok, document} = Store.Memory.load(store_of(instance), id)
    document
  end

  # A journal of n transactions that each set "n" to their revision.
  defp journal(range) do
    for revision <- range do
      %{
        "id" => "t#{revision}",
        "epoch" => "e1",
        "base_revision" => revision - 1,
        "ops" => [%{"op" => "set", "path" => ["n"], "value" => revision}],
        "revision" => revision,
        "author" => "u"
      }
    end
  end

  defp save(instance, document) do
    id = "canvas:" <> Transaction.id()
    :ok = Store.Memory.save(store_of(instance), id, nil, document, document["state"])
    id
  end

  test "a document keeps the latest :journal transactions, and rebuilds every revision they reach",
       %{capped: instance} do
    {id, pid} = open(instance)
    {:ok, %{"epoch" => epoch}} = Authority.snapshot(pid)
    commit_n(pid, 1..100)

    stored = stored(instance, id)
    base = stored["base"]
    assert length(stored["journal"]) in 8..10
    assert length(stored["journal"]) == 100 - base
    assert stored["initial"] == %{"n" => base}

    applies()

    for revision <- base..100,
        do: assert({:ok, %{"n" => ^revision}} = Authority.content_at(pid, epoch, revision))

    assert {:error, :unknown_revision} = Authority.content_at(pid, epoch, base - 1)
    assert {:error, :unknown_revision} = Authority.content_at(pid, epoch, 0)
    assert Issho.Test.replays?(instance, id)
  end

  test "folding the journal costs at most one more apply a commit", %{capped: instance} do
    {_id, pid} = open(instance)
    applies()
    commit_n(pid, 1..100)
    assert applies() <= 200
  end

  test "without :journal, a document keeps every transaction, as Issho 0.5.0 does",
       %{unbounded: instance} do
    {id, pid} = open(instance)
    {:ok, %{"epoch" => epoch}} = Authority.snapshot(pid)
    commit_n(pid, 1..30)

    stored = stored(instance, id)
    assert length(stored["journal"]) == 30
    assert Map.get(stored, "base", 0) == 0
    assert {:ok, %{}} = Authority.content_at(pid, epoch, 0)
    assert {:ok, %{"n" => 12}} = Authority.content_at(pid, epoch, 12)
  end

  test "a document saved with a journal longer than :journal opens without replaying it",
       %{capped: instance} do
    id =
      save(instance, %{
        "engine" => "observed",
        "engine_version" => 1,
        "epoch" => "e1",
        "revision" => 200,
        "state" => %{"n" => 200},
        "initial" => %{},
        "journal" => journal(1..200),
        "receipts" => %{}
      })

    {^id, pid} = open(instance, id: id)
    assert applies() == 0
    assert {:ok, %{"n" => 200}} = Authority.content_at(pid, "e1", 200)
    assert {:error, :unknown_revision} = Authority.content_at(pid, "e1", 199)

    {:ok, %{"revision" => 201}} = Authority.commit(pid, set_n(pid, 201), "u")
    assert applies() == 1

    assert %{"base" => 200, "initial" => %{"n" => 200}, "journal" => [%{"revision" => 201}]} =
             stored(instance, id)
  end

  test "a document saved with a journal within :journal opens with it",
       %{capped: instance} do
    id =
      save(instance, %{
        "engine" => "observed",
        "engine_version" => 1,
        "epoch" => "e1",
        "revision" => 10,
        "state" => %{"n" => 10},
        "initial" => %{},
        "journal" => journal(1..10),
        "receipts" => %{}
      })

    {^id, pid} = open(instance, id: id)
    assert {:ok, %{}} = Authority.content_at(pid, "e1", 0)
    assert {:ok, %{"n" => 3}} = Authority.content_at(pid, "e1", 3)
  end

  test "a journal that does not fold is kept as it is, and the commit goes on",
       %{capped: instance} do
    # A journal whose third transaction the engine cannot apply again.
    journal = List.update_at(journal(1..5), 2, &%{&1 | "ops" => [%{"op" => "raise"}]})

    id =
      save(instance, %{
        "engine" => "observed",
        "engine_version" => 1,
        "epoch" => "e1",
        "revision" => 5,
        "state" => %{"n" => 5},
        "initial" => %{},
        "journal" => journal,
        "receipts" => %{}
      })

    {^id, pid} = open(instance, id: id)

    log = capture_log(fn -> commit_n(pid, 6..20) end)
    assert log =~ id
    assert log =~ "cannot apply"

    stored = stored(instance, id)
    assert stored["revision"] == 20
    assert length(stored["journal"]) == 20 - stored["base"]

    capture_log(fn ->
      assert {:error, :replay_failed} = Authority.content_at(pid, "e1", 3)
    end)

    assert {:ok, %{"n" => 2}} = Authority.content_at(pid, "e1", 2)
    assert {:ok, %{"revision" => 21}} = Authority.commit(pid, set_n(pid, 21), "u")
  end

  test ":journal is nil or a number of transactions" do
    for journal <- [-1, :all] do
      assert_raise ArgumentError, ~r/:journal is nil or a number of transactions/, fn ->
        Issho.start_link(
          name: :journal_test,
          pubsub: :p,
          policy: Policy,
          secret_key_base: "k",
          journal: journal
        )
      end
    end
  end
end
