defmodule Issho.State do
  @moduledoc ~S"""
  Shared state without an engine of your own: a map that people and
  agents change together (`Issho.Engine.Map`), as a LiveView assign that
  stays up to date. A retro board, a poll, a checklist, a kanban's order,
  a game's turn.

  Define the document in your policy, as any document, with its initial
  content from your database and an `on_transaction` hook that checks a
  change and saves it (see `Issho.Documents.open/4`):

      def document(_who, "retro:" <> id = doc) do
        {:ok,
         %{
           engine: Issho.Engine.Map,
           initial: Retros.get!(id).state,
           on_transaction: fn _ops, %{after: state} -> Retros.save(id, state) end
         }}
      end

  Then, in a LiveView (with `on_mount Issho.Live`):

      def mount(%{"id" => id}, _session, socket) do
        room = "retro:" <> id

        if connected?(socket),
          do: {:ok, _} = Issho.Live.join(MyApp.Issho, socket.assigns.current_user, room)

        {:ok, socket |> assign(:room, room) |> Issho.State.assign(:retro, room)}
      end

      def handle_event("add", %{"text" => text}, socket) do
        card = %{"id" => Ecto.UUID.generate(), "text" => text, "votes" => 0}
        :ok = Issho.State.change(socket, :retro, [Issho.State.insert(["cards"], card)])
        {:noreply, socket}
      end

      def handle_event("vote", %{"id" => id}, socket) do
        :ok = Issho.State.change(socket, :retro, [Issho.State.increment(["cards", id, "votes"])])
        {:noreply, socket}
      end

  `@retro` is the state, a map, and changes as anyone changes it: this
  LiveView, another person's, an agent (the `update_state` tool), or your
  server (`Issho.transact/4`). It is the state the authority accepted, in
  its order, the same in every LiveView of the room.

  ## Operations

  `set/2`, `delete/1`, `increment/2`, and, for lists of items by id (the
  cards of a column), `insert/3`, `move/3` and `remove/2`. A path is a
  list of keys, and of items' ids through a list: `["columns", "todo",
  card_id, "title"]`. Concurrent changes merge as `Issho.Engine.Map`
  says: two people who add a card at once both have theirs.
  """

  @type path :: [String.t() | atom() | integer()]
  @type op :: map()

  @doc ~S"""
  Sets the value at a path, making the maps on the way.

      iex> Issho.State.set(["plan", :title], "Q3")
      %{"op" => "set", "path" => ["plan", "title"], "value" => "Q3"}
  """
  @spec set(path(), term()) :: op()
  def set(path, value), do: %{"op" => "set", "path" => keys(path), "value" => value}

  @doc "Deletes the value at a path: a key of a map, or an item of a list."
  @spec delete(path()) :: op()
  def delete(path), do: %{"op" => "delete", "path" => keys(path)}

  @doc "Adds to the number at a path (`1` unless given); a missing one is `0`."
  @spec increment(path(), number()) :: op()
  def increment(path, by \\ 1) when is_number(by),
    do: %{"op" => "increment", "path" => keys(path), "by" => by}

  @doc ~S"""
  Inserts an item (a map with an `"id"`) in the list at a path. Options:
  `:after` or `:before` an item's id, or `:at` (`:start` or `:end`, the
  end unless given).

      iex> Issho.State.insert(["cards"], %{"id" => "c2"}, after: "c1")
      %{"op" => "insert", "path" => ["cards"], "value" => %{"id" => "c2"}, "after" => "c1"}
  """
  @spec insert(path(), map(), keyword()) :: op()
  def insert(path, %{"id" => _} = item, opts \\ []),
    do: Map.merge(%{"op" => "insert", "path" => keys(path), "value" => item}, where(opts))

  @doc ~S"""
  Moves the item `id` of the list at a path, within it or to the list at
  `:to`, placed `:after` or `:before` an item's id, or `:at` (`:start` or
  `:end`). An `:after` or `:before` of `nil` is not given.

      iex> Issho.State.move(["cols", "todo"], "c1", to: ["cols", "done"], at: :start)
      %{"op" => "move", "path" => ["cols", "todo"], "id" => "c1", "to" => ["cols", "done"], "at" => "start"}
  """
  @spec move(path(), String.t(), keyword()) :: op()
  def move(path, id, opts \\ []) when is_binary(id) do
    op = %{"op" => "move", "path" => keys(path), "id" => id}
    op = if to = opts[:to], do: Map.put(op, "to", keys(to)), else: op
    Map.merge(op, where(opts))
  end

  @doc "Removes the item `id` from the list at a path."
  @spec remove(path(), String.t()) :: op()
  def remove(path, id) when is_binary(id), do: delete(path ++ [id])

  @doc ~S"""
  The value at a path of a state, through lists by items' ids, or `nil`.

      iex> state = %{"cols" => %{"todo" => [%{"id" => "c1", "title" => "Plan"}]}}
      iex> Issho.State.get(state, ["cols", "todo", "c1", "title"])
      "Plan"
      iex> Issho.State.get(state, ["cols", "done"])
      nil
  """
  @spec get(map() | nil, path()) :: term()
  def get(state, path), do: path |> keys() |> Enum.reduce(state, &step/2)

  defp step(key, %{} = map), do: Map.get(map, key)
  defp step(id, list) when is_list(list), do: Enum.find(list, &match?(%{"id" => ^id}, &1))
  defp step(_key, _value), do: nil

  defp keys(path) when is_list(path), do: Enum.map(path, &to_string/1)

  defp where(opts) do
    case opts do
      [{:after, id} | _] when is_binary(id) -> %{"after" => id}
      [{:before, id} | _] when is_binary(id) -> %{"before" => id}
      [{:at, at} | _] when at in [:start, :end] -> %{"at" => Atom.to_string(at)}
      [_ | rest] -> where(rest)
      [] -> %{}
    end
  end

  if Code.ensure_loaded?(Phoenix.LiveView) do
    alias Issho.Live
    alias Phoenix.LiveView.Socket

    @doc """
    Assigns a document of the room as `key`, kept up to date as it
    changes: the LiveView must be in the room (`Issho.Live.join/4`), and the
    document's engine `Issho.Engine.Map`. In the static render, before the
    LiveView is connected and in the room, `key` is `:default` (`%{}`).
    """
    @spec assign(Socket.t(), atom(), String.t(), String.t() | nil, keyword()) :: Socket.t()
    def assign(socket, key, room, document \\ nil, opts \\ []) when is_atom(key) do
      document = document || room

      if Live.session_id(room) do
        case Live.open(room, document) do
          {:ok, %{"engine" => "map", "state" => state, "revision" => revision}} ->
            Process.put({__MODULE__, :document, document}, {key, room, revision})
            Process.put({__MODULE__, :key, key}, {room, document})
            Phoenix.Component.assign(socket, key, state)

          {:ok, %{"engine" => engine}} ->
            raise ArgumentError,
                  "Issho.State needs a document of Issho.Engine.Map, #{document} is #{engine}'s"

          {:error, reason} ->
            raise ArgumentError, "Issho.State could not open #{document}: #{inspect(reason)}"
        end
      else
        Phoenix.Component.assign(socket, key, Keyword.get(opts, :default, %{}))
      end
    end

    @doc """
    Changes the state assigned as `key`, with operations (`set/2`,
    `insert/3`...), as one transaction: all of them, or none. The assign
    changes when the room's authority accepts it, as everyone's does.
    Gives `:ok`, or `{:error, reason}` (your hook refused it, the policy, an
    operation).
    """
    @spec change(Socket.t(), atom(), [op()]) :: :ok | {:error, term()}
    def change(%Socket{}, key, ops) when is_atom(key) and is_list(ops) do
      case Process.get({__MODULE__, :key, key}) do
        nil ->
          {:error, :not_assigned}

        {room, document} ->
          with {:ok, _receipt} <- Live.transact(room, document, ops), do: :ok
      end
    end

    @doc false
    # A transaction accepted in a document assigned as state: the assign
    # after it. One the LiveView has already, it skips; after one it
    # missed, it reads the document again.
    @spec __transaction__(Socket.t(), String.t(), map()) :: Socket.t()
    def __transaction__(socket, document, %{"revision" => revision, "ops" => ops} = event) do
      case Process.get({__MODULE__, :document, document}) do
        nil ->
          socket

        {_key, _room, seen} when revision <= seen ->
          socket

        {key, room, seen} when revision == seen + 1 ->
          {:ok, state} =
            Issho.Engine.Map.apply(socket.assigns[key], ops, author: event["author"])

          Process.put({__MODULE__, :document, document}, {key, room, revision})
          Phoenix.Component.assign(socket, key, state)

        {key, room, _seen} ->
          {:ok, %{"state" => state, "revision" => now}} = Live.read(room, document)
          Process.put({__MODULE__, :document, document}, {key, room, now})
          Phoenix.Component.assign(socket, key, state)
      end
    end
  end
end
