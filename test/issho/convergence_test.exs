defmodule Issho.ConvergenceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Issho.{Participant, Transaction}

  defmodule Policy do
    @moduledoc false
    @behaviour Issho.Policy
    @impl true
    def authorize(_identity, _room, _action), do: :ok
    @impl true
    def document(_identity, _id), do: {:ok, %{engine: Issho.Engine.Map, initial: %{}}}
  end

  setup do
    %{instance: Issho.Test.start!(policy: Policy)}
  end

  defp op_gen do
    key = member_of(~w(a b c d))

    one_of([
      map({key, integer(-5..5)}, fn {k, v} ->
        %{"op" => "set", "path" => ["k", k], "value" => v}
      end),
      map(key, fn k -> %{"op" => "delete", "path" => ["k", k]} end),
      map({key, integer(1..3)}, fn {k, by} ->
        %{"op" => "increment", "path" => ["n", k], "by" => by}
      end)
    ])
  end

  property "concurrent participants: every accepted transaction is in the journal once, in one order",
           %{instance: instance} do
    check all(
            plans <-
              list_of(list_of(list_of(op_gen(), min_length: 1, max_length: 3), max_length: 8),
                length: 4
              ),
            max_runs: 25
          ) do
      room = "doc:" <> Transaction.id()

      participants =
        for i <- 1..4 do
          {:ok, p} = Issho.join_as(instance, %{id: "p#{i}"}, room, notify: nil)
          {:ok, _} = Participant.open(p, room)
          p
        end

      results =
        participants
        |> Enum.zip(plans)
        |> Enum.map(fn {p, plan} ->
          Task.async(fn -> Enum.map(plan, &Participant.transact(p, room, &1)) end)
        end)
        |> Enum.flat_map(&Task.await(&1, 10_000))

      # Sets and increments use separate keys, so every transaction applies:
      # each gets its own revision, with no gap and no repeat.
      revisions = for {:ok, %{"revision" => r}} <- results, do: r
      assert length(revisions) == length(Enum.concat(plans))
      assert Enum.sort(revisions) == Enum.to_list(1..length(revisions)//1)
      assert Issho.Test.replays?(instance, room)

      Enum.each(participants, &Participant.leave/1)
    end
  end
end
