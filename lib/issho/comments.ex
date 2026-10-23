defmodule Issho.Comments do
  @moduledoc ~S"""
  Threads of comments on the places of a room's components: a range of a
  text, a node of a canvas, a cell of a grid, or the page as a whole.
  People and agents start them, reply, edit and delete their own, react,
  mention each other, resolve and reopen them.

  A room's threads are a document of the room, `"board:42/issho.comments"`
  (`document/1`), with Issho's own engine (`Issho.Engine.Comments`): it is
  Issho's, whatever your policy's `document/2` says of that id, kept in
  the instance's store, shared and live as any document is. Your policy
  says who may comment: a change to it asks for `:comment`, not `:write`,
  so a reader with a `can: :read` grant may comment when your policy
  allows it (`Issho.Policy`).

  ## From your server

      ada = %{id: "user:ada", name: "Ada"}
      place = %{"doc" => "board:42", "at" => %{"node" => "n7"}}

      {:ok, %{thread: thread}} =
        Issho.Comments.start(MyApp.Issho, "board:42", ada, place, "Should this go first?",
          mentions: ["agent:claude"])

      {:ok, _} = Issho.Comments.reply(MyApp.Issho, "board:42", claude, thread, "Yes: it blocks the rest.")
      {:ok, _} = Issho.Comments.resolve(MyApp.Issho, "board:42", ada, thread)
      {:ok, threads} = Issho.Comments.threads(MyApp.Issho, "board:42")

  An actor is an `Issho.Actor`, or an `Issho.Identity` (an agent and whom it
  acts for). From a LiveView, an agent's participant or a browser, the
  same changes are operations of the comments document (`Issho.Comments.Ops`),
  committed under the policy as any change.

  ## Who wrote it, and when

  Each comment names its author and its time. Before a change is
  accepted, Issho holds them to the writer: the author is the signed
  identity of whoever made the change (its key, name, kind, avatar, colour
  and whom it acts for), and the time is within a few minutes of the
  server's clock, so a browser cannot write as someone else, or in the
  past. A thread's place is in the room.

  ## Events

  After each change is saved, the room has its events (`Issho.Events`):

    * `"thread.created"`: `%{thread: id, comment: id, place: place, body: text, mentions: [key]}`;
    * `"comment.created"`: every new comment, the first of a thread too,
      `%{thread: id, comment: id, place: place, body: text, mentions: [key], reply: boolean}`;
    * `"comment.edited"` (`body`, `mentions`) and `"comment.deleted"`;
    * `"thread.resolved"` and `"thread.reopened"`: `%{thread: id, place: place}`.

  An agent mentioned in a comment hears it (`wait_for_events` with
  `mentions_me`), and answers in the thread (the `comment` tool).
  """

  alias Issho.{Authority, Documents, Identity, Policy}
  alias Issho.Comments.Ops

  @suffix "issho.comments"
  # How far a comment's time may be from the server's clock.
  @skew_seconds 300

  @doc ~S"""
  The comments document of a room.

      iex> Issho.Comments.document("board:42")
      "board:42/issho.comments"
  """
  @spec document(String.t()) :: String.t()
  def document(room) when is_binary(room), do: room <> "/" <> @suffix

  @doc ~S"""
  Whether a document is a room's comments.

      iex> Issho.Comments.document?("board:42/issho.comments")
      true
      iex> Issho.Comments.document?("board:42/n7/issho.comments")
      false
  """
  @spec document?(String.t()) :: boolean()
  def document?(id) when is_binary(id), do: id == document(Policy.room(id))

  @doc false
  # What a room's comments document is, whatever the policy says.
  @spec spec() :: map()
  def spec, do: %{engine: Issho.Engine.Comments, on_transaction: &check/2, events: &events/2}

  @doc "The threads of a room, in the order they began."
  @spec threads(atom(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def threads(instance, room) do
    with {:ok, pid} <- Documents.open(instance, document(room)),
         {:ok, %{"state" => %{"threads" => threads}}} <- Authority.snapshot(pid),
         do: {:ok, threads}
  end

  @doc """
  Starts a thread at a place (`nil` for the page as a whole), with its
  first comment. Options: `:mentions`, the keys of the actors it mentions.
  Gives `{:ok, %{thread: id, comment: id}}`.
  """
  @spec start(
          atom(),
          String.t(),
          Issho.Actor.t() | Identity.t(),
          map() | nil,
          String.t(),
          keyword()
        ) ::
          {:ok, %{thread: String.t(), comment: String.t()}} | {:error, term()}
  def start(instance, room, actor, place, body, opts \\ []) do
    {op, ids} = Ops.start(Identity.new(actor), place, body, opts)
    with {:ok, _} <- commit(instance, room, actor, [op]), do: {:ok, ids}
  end

  @doc "Replies in a thread. Options: `:mentions`. Gives `{:ok, %{thread: id, comment: id}}`."
  @spec reply(
          atom(),
          String.t(),
          Issho.Actor.t() | Identity.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, %{thread: String.t(), comment: String.t()}} | {:error, term()}
  def reply(instance, room, actor, thread, body, opts \\ []) do
    {op, ids} = Ops.reply(Identity.new(actor), thread, body, opts)
    with {:ok, _} <- commit(instance, room, actor, [op]), do: {:ok, ids}
  end

  @doc """
  Edits one's own comment. Options: `:mentions`, whom the comment
  mentions after the edit (none unless given).
  """
  @spec edit(
          atom(),
          String.t(),
          Issho.Actor.t() | Identity.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def edit(instance, room, actor, thread, comment, body, opts \\ []),
    do: commit(instance, room, actor, [Ops.edit(thread, comment, body, opts)])

  @doc "Deletes one's own comment; a thread with none left goes."
  @spec delete(atom(), String.t(), Issho.Actor.t() | Identity.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def delete(instance, room, actor, thread, comment),
    do: commit(instance, room, actor, [Ops.delete(thread, comment)])

  @doc "Adds the actor's reaction (an emoji) to a comment."
  @spec react(
          atom(),
          String.t(),
          Issho.Actor.t() | Identity.t(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, map()} | {:error, term()}
  def react(instance, room, actor, thread, comment, emoji),
    do: commit(instance, room, actor, [Ops.react(thread, comment, emoji)])

  @doc "Takes the actor's reaction back."
  @spec unreact(
          atom(),
          String.t(),
          Issho.Actor.t() | Identity.t(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, map()} | {:error, term()}
  def unreact(instance, room, actor, thread, comment, emoji),
    do: commit(instance, room, actor, [Ops.unreact(thread, comment, emoji)])

  @doc "Resolves a thread."
  @spec resolve(atom(), String.t(), Issho.Actor.t() | Identity.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve(instance, room, actor, thread),
    do: commit(instance, room, actor, [Ops.resolve(thread)])

  @doc "Reopens a resolved thread."
  @spec reopen(atom(), String.t(), Issho.Actor.t() | Identity.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def reopen(instance, room, actor, thread),
    do: commit(instance, room, actor, [Ops.reopen(thread)])

  # Your server's own change, for an actor: under no policy, as
  # Issho.transact/4's are, but held to the actor as everyone's is.
  defp commit(instance, room, actor, ops),
    do: Issho.transact(instance, document(room), ops, author: Identity.new(actor))

  @doc false
  # The comments document's hook: each new comment's author is whoever
  # made the change, its times near the server's, its places in the room.
  @spec check([map()], map()) :: :ok | {:error, term()}
  def check(ops, %{by: by, document: document}) do
    author = Ops.author(by)
    room = Policy.room(document)

    Enum.reduce_while(ops, :ok, fn op, :ok ->
      case check_op(op, author, room) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_op(%{"op" => op, "comment" => %{} = comment} = whole, author, room)
       when op in ["start", "reply"] do
    cond do
      comment["author"] != author -> {:error, :not_the_author}
      not recent?(comment["at"]) -> {:error, :invalid_time}
      true -> check_place(whole, room)
    end
  end

  defp check_op(%{"op" => op, "at" => at}, _author, _room) when op in ["edit", "resolve"],
    do: if(recent?(at), do: :ok, else: {:error, :invalid_time})

  defp check_op(%{"op" => "place"} = op, _author, room), do: check_place(op, room)
  defp check_op(_op, _author, _room), do: :ok

  defp check_place(%{"place" => %{"doc" => doc}}, room) when is_binary(doc) do
    if Policy.room(doc) == room, do: :ok, else: {:error, :other_room}
  end

  defp check_place(_op, _room), do: :ok

  defp recent?(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, 0} -> abs(DateTime.diff(time, DateTime.utc_now())) <= @skew_seconds
      _ -> false
    end
  end

  defp recent?(_at), do: false

  @doc false
  # The events of an accepted change to a room's comments.
  @spec events([map()], map()) :: [{String.t(), map()}]
  def events(ops, %{after: %{"threads" => threads}}) do
    Enum.flat_map(ops, fn op ->
      thread = Enum.find(threads, &(&1["id"] == op["thread"]))
      if thread, do: events_of(op, thread), else: []
    end)
  end

  defp events_of(%{"op" => "start", "comment" => %{"id" => id}}, thread) do
    comment = comment_of(thread, id)

    [
      {"thread.created", Map.merge(about(thread, comment), %{place: thread["place"]})},
      {"comment.created", Map.merge(about(thread, comment), %{reply: false})}
    ]
  end

  defp events_of(%{"op" => "reply", "comment" => %{"id" => id}}, thread),
    do: [{"comment.created", Map.merge(about(thread, comment_of(thread, id)), %{reply: true})}]

  defp events_of(%{"op" => "edit", "comment" => id}, thread),
    do: [{"comment.edited", about(thread, comment_of(thread, id))}]

  defp events_of(%{"op" => "delete", "comment" => id}, thread),
    do: [{"comment.deleted", %{thread: thread["id"], comment: id, place: thread["place"]}}]

  defp events_of(%{"op" => "resolve"}, thread),
    do: [{"thread.resolved", %{thread: thread["id"], place: thread["place"]}}]

  defp events_of(%{"op" => "reopen"}, thread),
    do: [{"thread.reopened", %{thread: thread["id"], place: thread["place"]}}]

  defp events_of(_op, _thread), do: []

  defp comment_of(thread, id), do: Enum.find(thread["comments"], &(&1["id"] == id)) || %{}

  defp about(thread, comment) do
    %{
      thread: thread["id"],
      comment: comment["id"],
      place: thread["place"],
      body: comment["body"],
      mentions: comment["mentions"] || []
    }
  end
end

defmodule Issho.Comments.Ops do
  @moduledoc ~S"""
  The operations of a room's comments document (`Issho.Engine.Comments`),
  for a LiveView, an agent's participant, or your own code to commit:

      ada = Issho.Identity.new(%{id: "user:ada", name: "Ada"})
      {op, %{thread: thread}} = Issho.Comments.Ops.start(ada, place, "Should this go first?")
      {:ok, _} = Issho.Live.transact(room, Issho.Comments.document(room), [op])

  A new comment is its author's, as their identity says it (`author/1`),
  at the server's time: the comments document's hook holds it to who
  commits it.
  """

  alias Issho.Identity

  @doc "A thread at a place, with its first comment: `{op, %{thread: id, comment: id}}`."
  @spec start(Identity.t(), map() | nil, String.t(), keyword()) :: {map(), map()}
  def start(%Identity{} = by, place, body, opts \\ []) do
    {comment, id} = comment(by, body, opts)
    thread = Keyword.get_lazy(opts, :thread, &new_id/0)

    {%{"op" => "start", "thread" => thread, "place" => place, "comment" => comment},
     %{thread: thread, comment: id}}
  end

  @doc "A reply in a thread: `{op, %{thread: id, comment: id}}`."
  @spec reply(Identity.t(), String.t(), String.t(), keyword()) :: {map(), map()}
  def reply(%Identity{} = by, thread, body, opts \\ []) do
    {comment, id} = comment(by, body, opts)
    {%{"op" => "reply", "thread" => thread, "comment" => comment}, %{thread: thread, comment: id}}
  end

  @doc "An edit of one's own comment."
  @spec edit(String.t(), String.t(), String.t(), keyword()) :: map()
  def edit(thread, comment, body, opts \\ []) do
    %{
      "op" => "edit",
      "thread" => thread,
      "comment" => comment,
      "body" => body,
      "mentions" => Keyword.get(opts, :mentions, []),
      "at" => now()
    }
  end

  @doc "A deletion of one's own comment."
  @spec delete(String.t(), String.t()) :: map()
  def delete(thread, comment), do: %{"op" => "delete", "thread" => thread, "comment" => comment}

  @doc "A reaction to a comment."
  @spec react(String.t(), String.t(), String.t()) :: map()
  def react(thread, comment, emoji),
    do: %{"op" => "react", "thread" => thread, "comment" => comment, "emoji" => emoji}

  @doc "A reaction taken back."
  @spec unreact(String.t(), String.t(), String.t()) :: map()
  def unreact(thread, comment, emoji),
    do: %{"op" => "unreact", "thread" => thread, "comment" => comment, "emoji" => emoji}

  @doc "A thread resolved."
  @spec resolve(String.t()) :: map()
  def resolve(thread), do: %{"op" => "resolve", "thread" => thread, "at" => now()}

  @doc "A thread reopened."
  @spec reopen(String.t()) :: map()
  def reopen(thread), do: %{"op" => "reopen", "thread" => thread}

  @doc "A thread at another place (its component's content moved)."
  @spec place(String.t(), map() | nil) :: map()
  def place(thread, place), do: %{"op" => "place", "thread" => thread, "place" => place}

  @doc """
  A comment's author, as an identity says it: its key, name, kind,
  avatar and colour, and the key and name of whom it acts for.
  """
  @spec author(Identity.t()) :: map()
  def author(%Identity{} = identity) do
    identity
    |> Identity.public()
    |> Map.take(["key", "name", "kind", "avatar", "color"])
    |> Map.put(
      "on_behalf_of",
      identity.on_behalf_of &&
        %{"key" => identity.on_behalf_of.key, "name" => identity.on_behalf_of.name}
    )
  end

  @doc false
  # The time of a change, as the comments document keeps it.
  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp comment(by, body, opts) do
    id = new_id()

    {%{
       "id" => id,
       "author" => author(by),
       "body" => body,
       "mentions" => Keyword.get(opts, :mentions, []),
       "at" => now()
     }, id}
  end

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
