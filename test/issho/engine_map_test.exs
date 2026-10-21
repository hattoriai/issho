defmodule Issho.Engine.MapTest do
  use ExUnit.Case, async: true

  alias Issho.Engine.Map, as: Engine

  test "sets, deletes and increments values at paths" do
    {:ok, state} = Engine.init(%{"a" => 1}, [])

    {:ok, state} =
      Engine.apply(
        state,
        [
          %{"op" => "set", "path" => ["plan", "title"], "value" => "Q3"},
          %{"op" => "increment", "path" => ["votes"], "by" => 2},
          %{"op" => "increment", "path" => ["votes"], "by" => 1},
          %{"op" => "delete", "path" => ["a"]}
        ],
        []
      )

    assert state == %{"plan" => %{"title" => "Q3"}, "votes" => 3}
  end

  test "applies a transaction's operations all or none" do
    {:ok, state} = Engine.init(nil, [])

    assert {:error, :invalid_path} =
             Engine.apply(
               state,
               [
                 %{"op" => "set", "path" => ["ok"], "value" => true},
                 %{"op" => "set", "path" => [], "value" => true}
               ],
               []
             )
  end

  test "refuses what is not JSON, and paths through values" do
    {:ok, state} = Engine.init(%{"title" => "x"}, [])

    assert {:error, :invalid_value} =
             Engine.apply(state, [%{"op" => "set", "path" => ["k"], "value" => {:tuple}}], [])

    assert {:error, :invalid_path} =
             Engine.apply(
               state,
               [%{"op" => "set", "path" => ["title", "deep"], "value" => 1}],
               []
             )

    assert {:error, :not_a_number} =
             Engine.apply(state, [%{"op" => "increment", "path" => ["title"], "by" => 1}], [])

    assert {:error, :invalid_operation} = Engine.apply(state, [%{"op" => "nope"}], [])
    assert {:error, :invalid_initial} = Engine.init(%{"k" => self()}, [])
  end

  test "deleting a missing key changes nothing" do
    {:ok, state} = Engine.init(%{"a" => %{"b" => 1}}, [])

    assert {:ok, ^state} =
             Engine.apply(state, [%{"op" => "delete", "path" => ["a", "x", "y"]}], [])
  end
end
