defmodule Issho.DocumentSpecTest do
  use ExUnit.Case, async: false

  alias Issho.{Authority, Documents, Transaction}

  @instance IsshoTest.Issho

  defp tx(pid, ops) do
    {:ok, snapshot} = Authority.snapshot(pid)

    %{
      "id" => Transaction.id(),
      "epoch" => snapshot["epoch"],
      "base_revision" => snapshot["revision"],
      "ops" => ops
    }
  end

  defp set(key, value), do: %{"op" => "set", "path" => [key], "value" => value}

  test "a spec from server code opens the document; the first open wins" do
    id = "canvas:" <> Transaction.id()
    spec = %{engine: Issho.Engine.Map, initial: %{"from" => "server"}, store: :none}
    {:ok, pid} = Documents.open(@instance, id, nil, spec: spec)
    assert {:ok, %{"state" => %{"from" => "server"}}} = Authority.snapshot(pid)

    other = %{engine: Issho.Engine.Map, initial: %{"from" => "second"}, store: :none}
    assert {:ok, ^pid} = Documents.open(@instance, id, nil, spec: other)
  end

  test "the hook runs once for each accepted transaction, before it is confirmed" do
    test = self()
    id = "canvas:" <> Transaction.id()

    hook = fn ops, context ->
      send(test, {:hook, ops, context})
      if context.after["title"] == "refused", do: {:error, :not_allowed}, else: :ok
    end

    spec = %{engine: Issho.Engine.Map, initial: %{}, store: :none, on_transaction: hook}
    {:ok, pid} = Documents.open(@instance, id, nil, spec: spec)

    t = tx(pid, [set("title", "Plan")])
    assert {:ok, %{"revision" => 1}} = Authority.commit(pid, t, "user:ada")

    assert_received {:hook, [%{"op" => "set"}],
                     %{author: "user:ada", revision: 1, before: %{}, after: %{"title" => "Plan"}}}

    # A retry does not run it again.
    assert {:ok, %{"duplicate" => true}} = Authority.commit(pid, t, "user:ada")
    refute_received {:hook, _, _}

    # A refusal changes nothing.
    assert {:error, :not_allowed} =
             Authority.commit(pid, tx(pid, [set("title", "refused")]), "user:ada")

    assert {:ok, %{"revision" => 1, "state" => %{"title" => "Plan"}}} = Authority.snapshot(pid)
  end

  @tag :capture_log
  test "a hook that raises refuses the transaction, and the document stays" do
    id = "canvas:" <> Transaction.id()
    spec = %{engine: Issho.Engine.Map, store: :none, on_transaction: fn _, _ -> raise "boom" end}
    {:ok, pid} = Documents.open(@instance, id, nil, spec: spec)

    assert {:error, :hook_failed} = Authority.commit(pid, tx(pid, [set("a", 1)]), "u")
    assert Process.alive?(pid)
    assert {:ok, %{"revision" => 0}} = Authority.snapshot(pid)
  end

  test "a document with no store starts again from its initial content" do
    id = "canvas:" <> Transaction.id()
    spec = %{engine: Issho.Engine.Map, initial: %{"n" => 0}, store: :none}
    {:ok, pid} = Documents.open(@instance, id, nil, spec: spec)
    {:ok, _} = Authority.commit(pid, tx(pid, [set("n", 5)]), "u")

    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, _, _, _}

    {:ok, again} = Documents.open(@instance, id, nil, spec: spec)
    assert {:ok, %{"state" => %{"n" => 0}, "revision" => 0}} = Authority.snapshot(again)
  end

  defmodule TermEngine do
    @moduledoc false
    # A state that is not JSON: a tuple list, as a struct of an app's would be.
    @behaviour Issho.Engine
    def name, do: "terms"
    def version, do: 1
    def init(nil, _opts), do: {:ok, %{items: []}}

    def apply(state, ops, _opts),
      do: {:ok, %{state | items: state.items ++ Enum.map(ops, &{:item, &1})}}
  end

  test "a document only the server holds can be any term" do
    id = "canvas:" <> Transaction.id()
    {:ok, pid} = Documents.open(@instance, id, nil, spec: %{engine: TermEngine, store: :none})
    {:ok, _} = Authority.commit(pid, tx(pid, [:one, :two]), "u")
    assert {:ok, %{"state" => %{items: [{:item, :one}, {:item, :two}]}}} = Authority.snapshot(pid)
    assert Issho.Test.replays?(@instance, id)
  end

  test "whereis finds a running document and starts none" do
    id = "canvas:" <> Transaction.id()
    assert Documents.whereis(@instance, id) == nil

    {:ok, pid} =
      Documents.open(@instance, id, nil, spec: %{engine: Issho.Engine.Map, store: :none})

    assert Documents.whereis(@instance, id) == pid
  end
end
