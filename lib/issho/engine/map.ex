defmodule Issho.Engine.Map do
  @moduledoc """
  A map that people and agents change together: values at paths, in the
  order the authority accepts them. It is the engine of shared assigns, the
  reference for writing an engine, and the engine of Issho's own tests.

      %{"op" => "set", "path" => ["plan", "title"], "value" => "Q3"}
      %{"op" => "delete", "path" => ["plan", "draft"]}
      %{"op" => "increment", "path" => ["votes"], "by" => 1}

  A path is a list of up to 16 strings. `set` makes the maps on its way;
  `delete` of a missing key does nothing. Concurrent `set`s of one path
  follow the authority's order; `increment`s add up. The initial content is
  a map (or `nil`, an empty one).

  Options: `:max_depth` of values (32).
  """

  @behaviour Issho.Engine

  @max_path 16

  @impl true
  def name, do: "map"

  @impl true
  def version, do: 1

  @impl true
  def init(nil, _opts), do: {:ok, %{}}

  def init(initial, opts) when is_map(initial) do
    if json?(initial, max_depth(opts)), do: {:ok, initial}, else: {:error, :invalid_initial}
  end

  def init(_initial, _opts), do: {:error, :invalid_initial}

  @impl true
  def apply(state, ops, opts) do
    Enum.reduce_while(ops, {:ok, state}, fn op, {:ok, acc} ->
      case op(acc, op, max_depth(opts)) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp op(state, %{"op" => "set", "path" => path, "value" => value}, depth) do
    with :ok <- check_path(path),
         true <- json?(value, depth) || {:error, :invalid_value} do
      put(state, path, value)
    end
  end

  defp op(state, %{"op" => "delete", "path" => path}, _depth) do
    with :ok <- check_path(path), do: {:ok, delete(state, path)}
  end

  defp op(state, %{"op" => "increment", "path" => path, "by" => by}, _depth) when is_number(by) do
    with :ok <- check_path(path) do
      case get_in(state, path) do
        nil -> put(state, path, by)
        current when is_number(current) -> put(state, path, current + by)
        _ -> {:error, :not_a_number}
      end
    end
  rescue
    # get_in through a value that is not a map
    _ -> {:error, :invalid_path}
  end

  defp op(_state, _op, _depth), do: {:error, :invalid_operation}

  defp check_path(path) do
    if is_list(path) and path != [] and length(path) <= @max_path and Enum.all?(path, &key?/1),
      do: :ok,
      else: {:error, :invalid_path}
  end

  defp key?(key), do: is_binary(key) and byte_size(key) in 1..256

  defp put(map, [key], value) when is_map(map), do: {:ok, Map.put(map, key, value)}

  defp put(map, [key | rest], value) when is_map(map) do
    case Map.get(map, key, %{}) do
      child when is_map(child) ->
        with {:ok, child} <- put(child, rest, value), do: {:ok, Map.put(map, key, child)}

      _ ->
        {:error, :invalid_path}
    end
  end

  defp delete(map, [key]) when is_map(map), do: Map.delete(map, key)

  defp delete(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, child} when is_map(child) -> Map.put(map, key, delete(child, rest))
      _ -> map
    end
  end

  defp json?(_value, depth) when depth < 0, do: false

  defp json?(value, depth) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> is_binary(k) and json?(v, depth - 1) end)

  defp json?(value, depth) when is_list(value), do: Enum.all?(value, &json?(&1, depth - 1))

  defp json?(value, _depth),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp max_depth(opts), do: Keyword.get(opts, :max_depth, 32)
end
