defmodule Issho.EngineCorpusTest do
  # The cases of test/corpus, which assets/test runs against the browser's
  # engines too: both sides must give the same result.
  use ExUnit.Case, async: true

  for {name, engine, file} <- [
        {"map", Issho.Engine.Map, "engine_map.json"},
        {"comments", Issho.Engine.Comments, "engine_comments.json"}
      ] do
    corpus = Path.expand("../corpus/" <> file, __DIR__)
    @external_resource corpus

    for %{"name" => example_name} = example <- corpus |> File.read!() |> JSON.decode!() do
      @example example
      @engine engine
      test "#{name}: #{example_name}" do
        %{"initial" => initial, "steps" => steps, "expected" => expected} = @example
        {:ok, state} = @engine.init(initial, [])

        final =
          Enum.reduce(steps, state, fn step, state ->
            author = Map.get(step, "author", "author")

            case {@engine.apply(state, step["ops"], author: author), step["error"]} do
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
end
