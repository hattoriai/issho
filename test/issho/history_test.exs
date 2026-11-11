defmodule Issho.HistoryTest do
  # A document keeps the receipts of its latest transactions (the
  # instance's :history), not of every one: a transaction it can no longer
  # tell from one it applied is refused, :expired, and never applied twice.
  # Its journal (the instance's :journal) stays as Issho 0.5.0 reads it,
  # across folds and compactions.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Issho.{Authority, Documents, Store, Transaction}

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
    unique = System.unique_integer([:positive])
    store = start_supervised!({Store.Memory, name: :"Issho.HistoryTest.Store#{unique}"})
    pubsub = :"Issho.HistoryTest.PubSub#{unique}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # {:history, :journal}
    instances =
      Map.new([{20, 4}, {27, 30}, {nil, nil}, {nil, 0}], fn {keep, cap} = limits ->
        {limits,
         Issho.Test.start!(
           policy: Policy,
           pubsub: pubsub,
           history: keep,
           journal: cap,
           store: {Store.Memory, store},
           compact: true,
           ttl: @ttl
         )}
      end)

    %{instance: instances[{20, 4}], instances: instances, store: store}
  end

  # Each transaction counts, under its own id, how many times it applied.
  defp tx(epoch, base) do
    id = Transaction.id()

    %{
      "id" => id,
      "epoch" => epoch,
      "base_revision" => base,
      "ops" => [%{"op" => "increment", "path" => ["n", id], "by" => 1}]
    }
  end

  defp tx(pid) do
    {:ok, %{"epoch" => epoch, "revision" => revision}} = Authority.snapshot(pid)
    tx(epoch, revision)
  end

  defp applied(pid, transaction) do
    {:ok, %{"state" => state}} = Authority.snapshot(pid)
    get_in(state, ["n", transaction["id"]])
  end

  defp advance(pid, n) do
    for _ <- 1..n, do: {:ok, _} = Authority.commit(pid, tx(pid), "user:ken")
    :ok
  end

  # Open while the test has it, as a page has it while it is open.
  defp open(instance, id \\ "doc:" <> Transaction.id()) do
    {:ok, pid} = Documents.open(instance, id)
    {:ok, _snapshot, _engine} = Authority.join(pid, self())
    {id, pid}
  end

  defp reopen(instance, id, pid) do
    :ok = GenServer.stop(pid)
    await_gone(instance, id, pid)
    {^id, again} = open(instance, id)
    again
  end

  defp await_gone(instance, id, pid) do
    if Documents.whereis(instance, id) == pid do
      Process.sleep(1)
      await_gone(instance, id, pid)
    end
  end

  test "a retry older than the latest :history transactions is refused, and applied once",
       %{instance: instance} do
    {_id, pid} = open(instance)
    t = tx(pid)
    assert {:ok, %{"revision" => 1}} = Authority.commit(pid, t, "user:ada")
    advance(pid, 5)
    assert {:ok, %{"revision" => 1, "duplicate" => true}} = Authority.commit(pid, t, "user:ada")

    advance(pid, 25)
    assert {:error, :expired} = Authority.commit(pid, t, "user:ada")
    assert applied(pid, t) == 1
  end

  test "a transaction sent late applies once when made on one of the latest :history revisions",
       %{instance: instance} do
    {_id, pid} = open(instance)
    advance(pid, 10)
    recent = tx(pid)
    {:ok, %{"epoch" => epoch}} = Authority.snapshot(pid)
    old = tx(epoch, 4)
    advance(pid, 20)

    assert {:ok, %{"revision" => 31}} = Authority.commit(pid, recent, "user:ada")
    assert {:ok, %{"duplicate" => true}} = Authority.commit(pid, recent, "user:ada")
    assert applied(pid, recent) == 1

    # Made before them, it cannot be told from one whose receipt is gone.
    assert {:error, :expired} = Authority.commit(pid, old, "user:ada")
    assert applied(pid, old) == nil
  end

  test "a stale transaction counts every change since, though their receipts are gone",
       %{instance: instance} do
    {_id, pid} = open(instance)
    {:ok, %{"epoch" => epoch}} = Authority.snapshot(pid)
    advance(pid, 30)
    conditional = Map.put(tx(epoch, 0), "if_revision", 0)

    assert {:error, {:stale, %{"count" => 30, "changes" => changes, "complete" => false}}} =
             Authority.commit(pid, conditional, "user:ada")

    assert Enum.map(changes, & &1["revision"]) == Enum.to_list(11..30)
  end

  test "the store keeps the latest receipts, and a reopened document still knows its horizon",
       %{instance: instance, store: store} do
    {id, pid} = open(instance)
    old = tx(pid)
    {:ok, _} = Authority.commit(pid, old, "user:ada")
    advance(pid, 99)
    recent = tx(pid)
    {:ok, %{"revision" => 101}} = Authority.commit(pid, recent, "user:ada")

    {:ok, stored} = Store.Memory.load(store, id)
    assert map_size(stored["receipts"]) in 20..25

    pid = reopen(instance, id, pid)
    assert {:error, :expired} = Authority.commit(pid, old, "user:ada")

    assert {:ok, %{"revision" => 101, "duplicate" => true}} =
             Authority.commit(pid, recent, "user:ada")

    assert applied(pid, old) == 1
  end

  test "a document opened with a larger :history still refuses what a smaller one forgot",
       %{instances: instances} do
    {id, pid} = open(instances[{20, 4}])
    advance(pid, 75)
    t = tx(pid)
    {:ok, %{"revision" => 76}} = Authority.commit(pid, t, "user:ada")
    advance(pid, 25)
    :ok = GenServer.stop(pid)

    {^id, pid} = open(instances[{27, 30}], id)
    assert {:error, :expired} = Authority.commit(pid, t, "user:ada")
    assert applied(pid, t) == 1
  end

  test "a document saved with every receipt opens with the latest, and saves only those",
       %{instance: instance, store: store} do
    id = "doc:" <> Transaction.id()

    transactions =
      for revision <- 1..40, do: {revision, %{tx("e1", revision - 1) | "id" => "t#{revision}"}}

    receipts =
      Map.new(transactions, fn {revision, t} ->
        {t["id"],
         %{
           "digest" => Transaction.digest(t, "user:ada"),
           "revision" => revision,
           "author" => "user:ada"
         }}
      end)

    journal =
      for {revision, t} <- transactions,
          do: Map.merge(t, %{"revision" => revision, "author" => "user:ada"})

    state = %{"n" => Map.new(transactions, fn {_revision, t} -> {t["id"], 1} end)}

    # As Issho 0.5.0 saves it: every receipt, and the journal from revision 0.
    stored = %{
      "engine" => "compacting",
      "engine_version" => 1,
      "epoch" => "e1",
      "revision" => 40,
      "state" => state,
      "initial" => %{},
      "journal" => journal,
      "receipts" => receipts
    }

    :ok = Store.Memory.save(store, id, nil, stored, state)
    {^id, pid} = open(instance, id)
    found = Map.new(transactions)

    assert {:ok, %{"revision" => 35, "duplicate" => true}} =
             Authority.commit(pid, found[35], "user:ada")

    assert {:error, :expired} = Authority.commit(pid, found[5], "user:ada")

    {:ok, _} = Authority.commit(pid, tx(pid), "user:ada")
    {:ok, saved} = Store.Memory.load(store, id)
    assert map_size(saved["receipts"]) in 20..25
  end

  test "without :history, a document keeps every receipt, as Issho 0.5.0 does",
       %{instances: instances, store: store} do
    {id, pid} = open(instances[{nil, nil}])
    old = tx(pid)
    {:ok, %{"revision" => 1}} = Authority.commit(pid, old, "user:ada")
    advance(pid, 99)

    pid = reopen(instances[{nil, nil}], id, pid)
    assert {:ok, %{"revision" => 1, "duplicate" => true}} = Authority.commit(pid, old, "user:ada")

    {:ok, %{"epoch" => epoch}} = Authority.snapshot(pid)
    assert {:ok, %{"revision" => 101}} = Authority.commit(pid, tx(epoch, 0), "user:ada")

    {:ok, stored} = Store.Memory.load(store, id)
    assert map_size(stored["receipts"]) == 101
    assert applied(pid, old) == 1
  end

  test ":history is nil or a number of transactions, at least 20" do
    for history <- [5, :all] do
      assert_raise ArgumentError,
                   ~r/:history is nil or a number of transactions, at least 20/,
                   fn ->
                     Issho.start_link(
                       name: :history_test,
                       pubsub: :p,
                       policy: Policy,
                       secret_key_base: "k",
                       history: history
                     )
                   end
    end
  end

  # Of the transactions made, some are sent at once and some later (an
  # offline tab), mostly on a recent revision, some up to three times
  # :history behind, and any is sent again (a lost reply, a reconnect), now
  # and then across a restart of the document's authority, or a compaction
  # when its last session leaves.
  defp step do
    behind = frequency([{4, integer(0..2)}, {2, integer(0..30)}, {1, integer(0..80)}])

    frequency([
      {4, tuple({constant(:send), behind})},
      {2, tuple({constant(:hold), behind})},
      {4, tuple({constant(:retry), non_negative_integer()})},
      {1, constant(:restart)},
      {1, constant(:compact)}
    ])
  end

  property "a transaction applies at most once, is refused only when older than :history or two epochs back, and the journal replays",
           %{instances: instances, store: store} do
    check all(
            {keep, cap} = limits <- member_of(Map.keys(instances)),
            steps <- resize(list_of(step(), min_length: 200, max_length: 400), 400),
            max_runs: 30
          ) do
      instance = instances[limits]
      {id, pid} = open(instance)
      {:ok, %{"epoch" => epoch}} = Authority.snapshot(pid)

      start = %{
        instance: instance,
        store: store,
        id: id,
        epoch: epoch,
        continues: nil,
        keep: keep,
        cap: cap,
        pid: pid,
        revision: 0
      }

      model = Enum.reduce(steps, Map.put(start, :made, []), &run/2)

      {:ok, %{"state" => state, "revision" => revision}} = Authority.snapshot(model.pid)
      assert revision == model.revision
      assert revision == Enum.count(model.made, & &1.applied)
      assert state |> Map.get("n", %{}) |> Map.values() |> Enum.all?(&(&1 == 1))

      stored = assert_stored(model)

      if keep,
        do: assert(map_size(stored["receipts"]) <= keep + div(keep, 4)),
        else: assert(map_size(stored["receipts"]) == revision)
    end
  end

  # The stored document as Issho 0.5.0 reads it: a journal of the
  # transactions after revision "base" (0 without one), which replays from
  # "initial", each with its author, to the content; no longer than the
  # instance's :journal and a quarter.
  defp assert_stored(model) do
    {:ok, stored} = Store.Memory.load(model.store, model.id)
    base = Map.get(stored, "base", 0)
    journal = stored["journal"]
    assert length(journal) == stored["revision"] - base
    if model.cap, do: assert(length(journal) <= model.cap + div(model.cap, 4))

    replayed =
      journal
      |> Enum.take(stored["revision"] - base)
      |> Enum.reduce(stored["initial"], fn event, state ->
        {:ok, next} = Compacting.apply(state, event["ops"], author: event["author"])
        next
      end)

    assert Compacting.validate(replayed, []) == {:ok, Store.Memory.content(model.store, model.id)}
    stored
  end

  defp run({:send, behind}, model) do
    made = %{tx: tx(model.epoch, max(model.revision - behind, 0)), applied: nil}
    {made, model} = deliver(made, model)
    %{model | made: model.made ++ [made]}
  end

  defp run({:hold, behind}, model) do
    made = %{tx: tx(model.epoch, max(model.revision - behind, 0)), applied: nil}
    %{model | made: model.made ++ [made]}
  end

  defp run({:retry, _n}, %{made: []} = model), do: model

  defp run({:retry, n}, model) do
    index = rem(n, length(model.made))
    {made, model} = deliver(Enum.at(model.made, index), model)
    %{model | made: List.replace_at(model.made, index, made)}
  end

  defp run(:restart, model) do
    assert_stored(model)
    %{model | pid: reopen(model.instance, model.id, model.pid)}
  end

  # Trash enough to be worth compacting, then the last session leaves.
  defp run(:compact, model) do
    trash = %{"op" => "set", "path" => ["trash"], "value" => String.duplicate("x", 100_000)}
    made = %{tx: %{tx(model.epoch, model.revision) | "ops" => [trash]}, applied: nil}
    {made, model} = deliver(made, model)

    ref = Process.monitor(model.pid)
    Authority.leave(model.pid, self())
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000
    await_gone(model.instance, model.id, model.pid)

    model = %{model | made: model.made ++ [made]}
    assert %{"continues" => continues, "epoch" => epoch} = assert_stored(model)
    assert continues == model.epoch
    {_id, pid} = open(model.instance, model.id)
    %{model | pid: pid, epoch: epoch, continues: continues}
  end

  # What the authority may answer, given what the transaction is: its
  # receipt is kept while it is one of the latest :history (all of them
  # without one), from any epoch; a transaction made on one of the latest
  # :history revisions without a receipt is new, when it was made on the
  # document's epoch or the one it continues.
  defp deliver(%{tx: t, applied: applied} = made, model) do
    latest = if model.keep, do: model.revision - model.keep, else: 0
    line? = t["epoch"] in [model.epoch, model.continues]

    case {Authority.commit(model.pid, t, "user:ada"), applied} do
      {{:ok, %{"duplicate" => true, "revision" => revision}}, revision} ->
        {made, model}

      {{:ok, %{"revision" => revision} = receipt}, nil} ->
        refute Map.has_key?(receipt, "duplicate")
        assert line?
        assert revision == model.revision + 1
        {%{made | applied: revision}, %{model | revision: revision}}

      {{:error, :expired}, nil} ->
        assert t["base_revision"] < latest
        {made, model}

      {{:error, :expired}, revision} ->
        assert revision <= latest
        {made, model}

      {{:error, :epoch_mismatch}, applied} ->
        refute line?
        if applied, do: assert(applied <= latest)
        {made, model}

      {other, applied} ->
        flunk("#{inspect(other)} for a transaction applied at #{inspect(applied)}")
    end
  end
end
