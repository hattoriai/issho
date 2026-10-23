defmodule Issho.Engine.Comments do
  @moduledoc """
  The threads of comments of a room: the engine of its comments document
  (`Issho.Comments`). Its browser twin is `commentsEngine`, held to the
  same cases (`test/corpus/engine_comments.json`).

  The state is `%{"threads" => [thread]}`, in the order they began:

      %{
        "id" => "t1",
        "place" => %{"doc" => "board:42", "at" => %{"node" => "n7"}},
        "status" => "open",
        "resolved" => nil,
        "comments" => [
          %{
            "id" => "c1",
            "author" => %{"key" => "user:ada", "name" => "Ada", "kind" => "human"},
            "body" => "Should this go first?",
            "mentions" => ["agent:claude"],
            "at" => "2026-10-23T10:00:00Z",
            "edited" => nil,
            "reactions" => %{"👍" => ["user:ken"]}
          }
        ]
      }

  A thread's place is where it is, in a component's own terms
  (`Issho.Place`), or `nil` for the page as a whole. `"resolved"` is
  `%{"by" => key, "at" => time}` while it is resolved.

  ## Operations

      %{"op" => "start", "thread" => "t1", "place" => place, "comment" => comment}
      %{"op" => "reply", "thread" => "t1", "comment" => comment}
      %{"op" => "edit", "thread" => "t1", "comment" => "c1", "body" => "...", "mentions" => [], "at" => time}
      %{"op" => "delete", "thread" => "t1", "comment" => "c1"}
      %{"op" => "react", "thread" => "t1", "comment" => "c1", "emoji" => "👍"}
      %{"op" => "unreact", "thread" => "t1", "comment" => "c1", "emoji" => "👍"}
      %{"op" => "resolve", "thread" => "t1", "at" => time}
      %{"op" => "reopen", "thread" => "t1"}
      %{"op" => "place", "thread" => "t1", "place" => place}

  A new comment (`"comment"` of `start` and `reply`) is `%{"id", "author",
  "body", "mentions", "at"}`. Its author's key is the key of whoever made
  the transaction (the engine's `:author` option), and only its author
  edits or deletes it; a reaction is the author's own. Deleting a thread's
  last comment deletes the thread. Anyone who may comment resolves,
  reopens and places a thread (a component places it again as its content
  moves).

  Concurrent changes merge: a reply, an edit, a reaction to a thread or a
  comment that is gone does nothing, as does resolving a resolved thread.
  The time of a comment is its writer's: `Issho.Comments` holds it, and
  the author's name, to the writer's signed identity and the server's
  clock before the change is accepted.
  """

  @behaviour Issho.Engine

  @max_body 20_000
  @max_mentions 50
  @max_emoji 32
  @max_reactions 50
  @max_place 4_096
  @time ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z\z/

  @impl true
  def name, do: "issho.comments"

  @impl true
  def version, do: 1

  @impl true
  def init(nil, _opts), do: {:ok, %{"threads" => []}}
  def init(%{"threads" => threads} = state, _opts) when is_list(threads), do: {:ok, state}
  def init(_initial, _opts), do: {:error, :invalid_initial}

  @impl true
  def apply(state, ops, opts) do
    author = Keyword.get(opts, :author)

    Enum.reduce_while(ops, {:ok, state}, fn op, {:ok, acc} ->
      case op(acc, op, author) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp op(state, %{"op" => "start", "thread" => id, "place" => place, "comment" => c}, author) do
    with :ok <- check_id(id),
         :ok <- check_place(place),
         {:ok, comment} <- new_comment(c, author) do
      if find(state["threads"], id),
        do: {:error, :duplicate_id},
        else: {:ok, %{state | "threads" => state["threads"] ++ [new_thread(id, place, comment)]}}
    end
  end

  defp op(state, %{"op" => "reply", "thread" => id, "comment" => c}, author) do
    with {:ok, comment} <- new_comment(c, author), do: thread(state, id, &add(&1, comment))
  end

  defp op(state, %{"op" => "edit", "thread" => id, "comment" => cid} = op, author) do
    with :ok <- check_body(op["body"]),
         :ok <- check_mentions(op["mentions"]),
         :ok <- check_time(op["at"]),
         do: comment(state, id, cid, &edit(&1, op, author))
  end

  defp op(state, %{"op" => "delete", "thread" => id, "comment" => cid}, author) do
    # A thread with no comment left goes.
    with {:ok, next} <- thread(state, id, &remove(&1, cid, author)),
         do: {:ok, %{next | "threads" => Enum.reject(next["threads"], &(&1["comments"] == []))}}
  end

  defp op(state, %{"op" => op, "thread" => id, "comment" => cid, "emoji" => emoji}, author)
       when op in ["react", "unreact"] do
    with :ok <- check_emoji(emoji),
         true <- is_binary(author) || {:error, :no_author},
         do: comment(state, id, cid, &react(&1, op, emoji, author))
  end

  defp op(state, %{"op" => "resolve", "thread" => id, "at" => at}, author) do
    with :ok <- check_time(at),
         true <- is_binary(author) || {:error, :no_author},
         do: thread(state, id, &resolve(&1, author, at))
  end

  defp op(state, %{"op" => "reopen", "thread" => id}, _author),
    do: thread(state, id, &{:ok, %{&1 | "status" => "open", "resolved" => nil}})

  defp op(state, %{"op" => "place", "thread" => id, "place" => place}, _author) do
    with :ok <- check_place(place), do: thread(state, id, &{:ok, %{&1 | "place" => place}})
  end

  defp op(_state, _op, _author), do: {:error, :invalid_operation}

  defp new_thread(id, place, comment),
    do: %{
      "id" => id,
      "place" => place,
      "status" => "open",
      "resolved" => nil,
      "comments" => [comment]
    }

  defp add(thread, comment) do
    if find(thread["comments"], comment["id"]),
      do: {:error, :duplicate_id},
      else: {:ok, %{thread | "comments" => thread["comments"] ++ [comment]}}
  end

  defp edit(comment, op, author) do
    if own?(comment, author),
      do:
        {:ok,
         %{comment | "body" => op["body"], "mentions" => op["mentions"], "edited" => op["at"]}},
      else: {:error, :not_the_author}
  end

  defp remove(thread, cid, author) do
    case find(thread["comments"], cid) do
      nil ->
        {:ok, thread}

      comment ->
        if own?(comment, author),
          do: {:ok, %{thread | "comments" => without(thread["comments"], cid)}},
          else: {:error, :not_the_author}
    end
  end

  defp react(comment, op, emoji, author) do
    reactions = comment["reactions"]
    keys = Map.get(reactions, emoji, [])

    cond do
      op == "unreact" ->
        {:ok, %{comment | "reactions" => put_reaction(reactions, emoji, keys -- [author])}}

      author in keys ->
        {:ok, comment}

      not Map.has_key?(reactions, emoji) and map_size(reactions) >= @max_reactions ->
        {:error, :too_many_reactions}

      true ->
        {:ok, %{comment | "reactions" => Map.put(reactions, emoji, keys ++ [author])}}
    end
  end

  defp resolve(%{"status" => "resolved"} = thread, _author, _at), do: {:ok, thread}

  defp resolve(thread, author, at),
    do: {:ok, %{thread | "status" => "resolved", "resolved" => %{"by" => author, "at" => at}}}

  # A thread changed by `fun`; one that is gone, the state as it is.
  defp thread(state, id, fun) do
    with {:ok, threads} <- change(state["threads"], id, fun),
         do: {:ok, %{state | "threads" => threads}}
  end

  # A comment changed by `fun`; one that is gone, the thread as it is.
  defp comment(state, id, cid, fun) do
    thread(state, id, fn thread ->
      with {:ok, comments} <- change(thread["comments"], cid, fun),
           do: {:ok, %{thread | "comments" => comments}}
    end)
  end

  # The item of a list with that id, changed by `fun`; with none, the list.
  defp change(list, id, fun) do
    case Enum.find_index(list, &(&1["id"] == id)) do
      nil ->
        {:ok, list}

      at ->
        with {:ok, item} <- fun.(Enum.at(list, at)), do: {:ok, List.replace_at(list, at, item)}
    end
  end

  defp new_comment(%{"id" => id, "author" => who, "body" => body, "at" => at} = c, author) do
    mentions = Map.get(c, "mentions", [])

    with :ok <- check_id(id),
         :ok <- check_author(who, author),
         :ok <- check_body(body),
         :ok <- check_mentions(mentions),
         :ok <- check_time(at) do
      {:ok,
       %{
         "id" => id,
         "author" => who,
         "body" => body,
         "mentions" => mentions,
         "at" => at,
         "edited" => nil,
         "reactions" => %{}
       }}
    end
  end

  defp new_comment(_comment, _author), do: {:error, :invalid_comment}

  defp check_id(id) do
    if is_binary(id) and byte_size(id) in 1..64, do: :ok, else: {:error, :invalid_id}
  end

  # The author a comment names is whoever made the transaction.
  defp check_author(%{"key" => key, "name" => name} = who, key)
       when is_binary(key) and (is_binary(name) or is_nil(name)) do
    if json_size(who) <= 2_048, do: :ok, else: {:error, :invalid_author}
  end

  defp check_author(_who, _author), do: {:error, :not_the_author}

  defp check_body(body) do
    if is_binary(body) and String.trim(body) != "" and byte_size(body) <= @max_body,
      do: :ok,
      else: {:error, :invalid_body}
  end

  defp check_mentions(mentions) do
    if is_list(mentions) and length(mentions) <= @max_mentions and
         Enum.all?(mentions, &(is_binary(&1) and byte_size(&1) in 1..256)),
       do: :ok,
       else: {:error, :invalid_mentions}
  end

  # A time as ISO 8601, in UTC, to the second or finer:
  # "2026-10-23T10:00:00Z", "2026-10-23T10:00:00.123Z".
  defp check_time(at) do
    with true <- is_binary(at) and Regex.match?(@time, at),
         {:ok, _time, 0} <- DateTime.from_iso8601(at) do
      :ok
    else
      _ -> {:error, :invalid_time}
    end
  end

  defp check_emoji(emoji) do
    if is_binary(emoji) and byte_size(emoji) in 1..@max_emoji,
      do: :ok,
      else: {:error, :invalid_emoji}
  end

  defp check_place(nil), do: :ok

  defp check_place(%{"doc" => doc} = place) when is_binary(doc) do
    if json_size(place) <= @max_place, do: :ok, else: {:error, :invalid_place}
  end

  defp check_place(_place), do: {:error, :invalid_place}

  defp own?(%{"author" => %{"key" => key}}, key) when is_binary(key), do: true
  defp own?(_comment, _author), do: false

  defp put_reaction(reactions, emoji, []), do: Map.delete(reactions, emoji)
  defp put_reaction(reactions, emoji, keys), do: Map.put(reactions, emoji, keys)

  defp find(list, id), do: Enum.find(list, &(&1["id"] == id))
  defp without(list, id), do: Enum.reject(list, &(&1["id"] == id))

  defp json_size(value) do
    byte_size(JSON.encode!(value))
  rescue
    _ -> :infinity
  end
end
