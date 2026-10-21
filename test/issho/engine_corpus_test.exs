defmodule Issho.EngineCorpusTest do
  # The cases of test/corpus, which assets/test runs against the browser's
  # engines too: both sides must give the same result.
  use ExUnit.Case, async: true

  @corpus Path.expand("../corpus/engine_map.json", __DIR__)
  @external_resource @corpus

  for %{"name" => name} = example <- @corpus |> File.read!() |> JSON.decode!() do
    @example example
    test "map: #{name}" do
      %{"initial" => initial, "steps" => steps, "expected" => expected} = @example
      {:ok, state} = Issho.Engine.Map.init(initial, [])

      final =
        Enum.reduce(steps, state, fn step, state ->
          case {Issho.Engine.Map.apply(state, step["ops"], []), step["error"]} do
            {{:ok, next}, nil} ->
              next

            {{:error, reason}, error} when is_binary(error) ->
              assert Atom.to_string(reason) == error
              state

            {result, error} ->
              flunk("step #{inspect(step)}: got #{inspect(result)}, wanted #{inspect(error)}")
          end
        end)

      assert final == expected
    end
  end
end
