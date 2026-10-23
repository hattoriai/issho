defmodule Issho.Engine.Map do
  @moduledoc """
  A map that people and agents change together: values at paths, and
  lists of items by their id, in the order the authority accepts them. It
  is the engine of shared state (`Issho.State`), the reference for writing
  an engine, and the engine of Issho's own tests.

      %{"op" => "set", "path" => ["plan", "title"], "value" => "Q3"}
      %{"op" => "delete", "path" => ["plan", "draft"]}
      %{"op" => "increment", "path" => ["votes"], "by" => 1}
      %{"op" => "insert", "path" => ["columns", "todo"], "value" => %{"id" => "c1", "title" => "Plan"}}
      %{"op" => "move", "path" => ["columns", "todo"], "id" => "c1", "to" => ["columns", "done"], "after" => "c7"}

  A path is a list of up to 16 strings. Through a map, a string is a key;
  through a list, it is the id of an item: `["columns", "todo", "c1",
  "title"]` is the title of the card `c1` in the list `todo`. `set` makes
  the maps on its way; `delete` of a missing key does nothing, and of an
  item removes it from its list.

  ## Lists

  A list of items is a list of maps, each with an `"id"` of its own (a
  string), as a kanban's cards, a checklist's entries, a retro's notes:

    * `insert` puts an item (`"value"`) in the list at `"path"`, made if
      it is missing: `"after"` or `"before"` an item's id, `"at"`
      `"start"` or `"end"` (the end unless given). An item whose id the
      list has already is refused (`duplicate_id`).
    * `move` takes the item `"id"` from the list at `"path"` to the list
      at `"to"` (the same list unless given), placed as `insert` places it.

  Concurrent changes merge: an item placed after one that is gone goes to
  the end; a change, move or delete of an item that is gone does nothing,
  as does a change through it. So two people who add cards at once both
  have theirs, and a card one person moves while another deletes it is
  deleted. Concurrent `set`s of one path follow the authority's order;
  `increment`s add up.

  The initial content is a map (or `nil`, an empty one). Options:
  `:max_depth` of values (32).

  Version 2 added lists of items; a document of version 1 upgrades as it
  is.
  """

  @behaviour Issho.Engine

  @max_path 16

  @impl true
  def name, do: "map"

  @impl true
  def version, do: 2

  @impl true
  def init(nil, _opts), do: {:ok, %{}}

  def init(initial, opts) when is_map(initial) do
    if json?(initial, max_depth(opts)), do: {:ok, initial}, else: {:error, :invalid_initial}
  end

  def init(_initial, _opts), do: {:error, :invalid_initial}

  # Version 1 had no lists of items: its states and operations are the same.
  @impl true
  def upgrade(%{"engine" => "map", "engine_version" => 1} = stored),
    do: {:ok, Map.take(stored, ["state", "epoch", "revision", "initial", "journal", "receipts"])}

  def upgrade(_stored), do: {:error, :unsupported_document}

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
      update(state, path, fn _current -> {:ok, value} end)
    end
  end

  defp op(state, %{"op" => "delete", "path" => path}, _depth) do
    with :ok <- check_path(path), do: {:ok, delete(state, path)}
  end

  defp op(state, %{"op" => "increment", "path" => path, "by" => by}, _depth) when is_number(by) do
    with :ok <- check_path(path) do
      update(state, path, fn
        nil -> {:ok, by}
        current when is_number(current) -> {:ok, current + by}
        _ -> {:error, :not_a_number}
      end)
    end
  end

  defp op(state, %{"op" => "insert", "path" => path, "value" => item} = op, depth) do
    with :ok <- check_path(path),
         :ok <- check_item(item, depth),
         {:ok, where} <- where(op) do
      update(state, path, fn current -> insert(current, item, where) end)
    end
  end

  defp op(state, %{"op" => "move", "path" => path, "id" => id} = op, _depth) do
    to = Map.get(op, "to", path)

    with :ok <- check_path(path),
         :ok <- check_path(to),
         true <- key?(id) || {:error, :invalid_id},
         {:ok, where} <- where(op) do
      move(state, path, id, to, where)
    end
  end

  defp op(_state, _op, _depth), do: {:error, :invalid_operation}

  # Where an item goes in a list.
  defp where(%{"after" => id}) when is_binary(id), do: {:ok, {:after, id}}
  defp where(%{"before" => id}) when is_binary(id), do: {:ok, {:before, id}}
  defp where(%{"at" => "start"}), do: {:ok, :start}
  defp where(%{"at" => "end"}), do: {:ok, :end}

  defp where(op) do
    if Enum.any?(["after", "before", "at"], &Map.has_key?(op, &1)),
      do: {:error, :invalid_operation},
      else: {:ok, :end}
  end

  defp check_path(path) do
    if is_list(path) and path != [] and length(path) <= @max_path and Enum.all?(path, &key?/1),
      do: :ok,
      else: {:error, :invalid_path}
  end

  defp key?(key), do: is_binary(key) and byte_size(key) in 1..256

  defp check_item(%{"id" => id} = item, depth) do
    cond do
      not key?(id) -> {:error, :invalid_id}
      not json?(item, depth) -> {:error, :invalid_value}
      true -> :ok
    end
  end

  defp check_item(_item, _depth), do: {:error, :invalid_value}

  # The value at a path given to `fun` (nil when missing), and what it
  # gives put there. Through a map, the maps on the way are made; through
  # a list, an item that is gone leaves the state as it is.
  defp update(map, [key], fun) when is_map(map) do
    with {:ok, value} <- fun.(Map.get(map, key)), do: {:ok, Map.put(map, key, value)}
  end

  defp update(map, [key | rest], fun) when is_map(map) do
    case Map.get(map, key, %{}) do
      child when is_map(child) or is_list(child) ->
        with {:ok, child} <- update(child, rest, fun), do: {:ok, Map.put(map, key, child)}

      _ ->
        {:error, :invalid_path}
    end
  end

  defp update(list, [id | rest], fun) when is_list(list) do
    case index(list, id) do
      nil -> if items?(list), do: {:ok, list}, else: {:error, :invalid_path}
      at -> update_item(list, at, id, rest, fun)
    end
  end

  defp update(_value, _path, _fun), do: {:error, :invalid_path}

  # An item set whole keeps its id.
  defp update_item(list, at, id, [], fun) do
    case fun.(Enum.at(list, at)) do
      {:ok, %{} = item} -> {:ok, List.replace_at(list, at, Map.put(item, "id", id))}
      {:ok, _other} -> {:error, :invalid_value}
      {:error, _reason} = error -> error
    end
  end

  defp update_item(list, at, _id, rest, fun) do
    with {:ok, item} <- update(Enum.at(list, at), rest, fun),
         do: {:ok, List.replace_at(list, at, item)}
  end

  defp delete(map, [key]) when is_map(map), do: Map.delete(map, key)
  defp delete(list, [id]) when is_list(list), do: Enum.reject(list, &item?(&1, id))

  defp delete(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, child} when is_map(child) or is_list(child) -> Map.put(map, key, delete(child, rest))
      _ -> map
    end
  end

  defp delete(list, [id | rest]) when is_list(list) do
    case index(list, id) do
      nil -> list
      at -> List.update_at(list, at, &delete(&1, rest))
    end
  end

  defp delete(value, _path), do: value

  defp insert(nil, item, where), do: insert([], item, where)

  defp insert(list, %{"id" => id} = item, where) when is_list(list) do
    if index(list, id), do: {:error, :duplicate_id}, else: {:ok, place(list, item, where)}
  end

  defp insert(_value, _item, _where), do: {:error, :not_a_list}

  # The item at its place in the list; after or before an item that is
  # gone, at the end.
  defp place(list, item, :start), do: [item | list]
  defp place(list, item, :end), do: list ++ [item]

  defp place(list, item, {side, id}) do
    case index(list, id) do
      nil -> list ++ [item]
      at when side == :after -> List.insert_at(list, at + 1, item)
      at -> List.insert_at(list, at, item)
    end
  end

  defp move(state, _path, id, _to, {_side, id}), do: {:ok, state}

  # An item that is gone, or a list to go to through an item that is
  # gone, leaves the state as it is.
  defp move(state, path, id, to, where) do
    with {:ok, list} <- list_at(state, path),
         %{} = item <- Enum.find(list, &item?(&1, id)),
         {:ok, _target} <- get(state, to) do
      # Out of its list, then into the other: a move within one list finds
      # the list without it.
      {:ok, without} = update(state, path, &{:ok, Enum.reject(&1, fn one -> item?(one, id) end)})
      update(without, to, &insert(&1, item, where))
    else
      nil -> {:ok, state}
      :gone -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end

  defp list_at(state, path) do
    case get(state, path) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, nil} -> :gone
      {:ok, _other} -> {:error, :not_a_list}
      other -> other
    end
  end

  # The value at a path: `{:ok, value}` (nil when missing), or `:gone`
  # through an item that is gone.
  defp get(value, []), do: {:ok, value}
  defp get(map, [key | rest]) when is_map(map), do: get(Map.get(map, key), rest)
  defp get(nil, _path), do: {:ok, nil}

  defp get(list, [id | rest]) when is_list(list) do
    case index(list, id) do
      nil -> if items?(list), do: :gone, else: {:error, :invalid_path}
      at -> get(Enum.at(list, at), rest)
    end
  end

  defp get(_value, _path), do: {:error, :invalid_path}

  defp index(list, id), do: Enum.find_index(list, &item?(&1, id))

  # A list of items, each a map with an id: through a list of other
  # values (`[1, 2]`) there is no path.
  defp items?(list), do: Enum.all?(list, &match?(%{"id" => id} when is_binary(id), &1))

  defp item?(%{"id" => id}, id), do: true
  defp item?(_value, _id), do: false

  defp json?(_value, depth) when depth < 0, do: false

  defp json?(value, depth) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> is_binary(k) and json?(v, depth - 1) end)

  defp json?(value, depth) when is_list(value), do: Enum.all?(value, &json?(&1, depth - 1))

  defp json?(value, _depth),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp max_depth(opts), do: Keyword.get(opts, :max_depth, 32)
end
