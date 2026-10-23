defmodule Issho.Inbox do
  @moduledoc ~S"""
  What was said to someone while they were away: each comment that
  mentions them, in any room, kept until they have read it. An agent
  that was not in the room when a person wrote "@Claude, a look?" finds
  it here when it next comes (the `inbox` tool), and the app can wake it
  at once (`:on_mention`).

  A comment that mentions someone (`"comment.created"`, its `mentions`)
  lands in the inbox of each it mentions, but its author; so does an
  app's own event with `mentions` in its data (`Issho.Events.emit/4`).
  An edit that adds a mention does not: the inbox is of what was said to
  them, once.

      {:ok, items} = Issho.Inbox.items(MyApp.Issho, assistant, on_behalf_of: ada)
      :ok = Issho.Inbox.mark_read(MyApp.Issho, assistant, Enum.map(items, & &1["id"]))

  An item is the event as `Issho.Event.to_map/1` gives it (`"name"`,
  `"room"`, `"document"`, `"by"`, `"data"`, `"at"`), with its `"id"`
  and whether it was `"read"`. Its room's policy decides, when it is
  read, whether its reader may still see it (`:read`): one whose access
  was taken away does not.

  An inbox is a document of Issho's (`document/1`), kept by the
  instance's store as the rooms' documents are, and never opened in a
  room. It keeps the last 200 items.

  ## Waking an agent

  MCP has no way to reach an agent that is not connected. So, for each
  mention, Issho:

    * calls the instance's `:on_mention`, `{module, function}` or a
      function of two arguments, with the key mentioned and the item, in
      a process of its own: the app starts its agent (a job, a webhook,
      a chat message to its owner);
    * tells the connected MCP clients that the `issho://inbox` resource
      changed (`Issho.MCP`), and its server's instructions say to read
      the inbox at the start of a session.

  ## In a cluster

  An event is delivered once in the cluster: on the node where the
  comment was saved, after it was, or where the app emitted its event.
  """

  require Logger

  # Issho.MCP is compiled only with Sake (see nudge/0).
  @compile {:no_warn_undefined, Issho.MCP}

  alias Issho.{Authority, Config, Documents, Event, Identity, Policy}

  @prefix "issho.inbox/"
  @kept 200

  @typedoc "An item: an event that mentioned its reader, with its id and whether it was read."
  @type item :: map()

  @doc "The document of the inbox of the actor with this key."
  @spec document(String.t()) :: String.t()
  def document(key) when is_binary(key), do: @prefix <> key

  @doc false
  @spec document?(String.t()) :: boolean()
  def document?(id) when is_binary(id), do: String.starts_with?(id, @prefix)

  @doc false
  def spec, do: %{engine: Issho.Engine.Map}

  @doc """
  The items of an actor's inbox, newest first: those not read yet, or
  all with `all: true`; only those of rooms the policy lets it `:read`.
  `actor` is an actor or an `Issho.Identity`. Options: `:all`,
  `:limit` (50), and `:on_behalf_of` and `:claims`, for the policy.
  """
  @spec items(atom(), Issho.Actor.t() | Identity.t(), keyword()) ::
          {:ok, [item()]} | {:error, term()}
  def items(instance, actor, opts \\ []) do
    identity = Identity.new(actor, Keyword.take(opts, [:on_behalf_of, :claims]))
    policy = Config.get(instance).policy

    with {:ok, all} <- stored(instance, identity.key) do
      readable =
        all
        |> Enum.map(& &1["room"])
        |> Enum.uniq()
        |> Enum.filter(&(Policy.authorize(policy, identity, &1, :read) == :ok))
        |> MapSet.new()

      items =
        all
        |> Enum.filter(&(&1["room"] in readable and (opts[:all] || not &1["read"])))
        |> Enum.reverse()
        |> Enum.take(Keyword.get(opts, :limit, 50))

      {:ok, items}
    end
  end

  @doc """
  Marks items of an inbox read, by their ids, or all of them with `:all`:
  the inbox of an actor, an `Issho.Identity`, or a key.
  """
  @spec mark_read(atom(), Issho.Actor.t() | Identity.t() | String.t(), [String.t()] | :all) ::
          :ok | {:error, term()}
  def mark_read(instance, actor, ids) do
    key = if is_binary(actor), do: actor, else: Identity.new(actor).key

    with {:ok, all} <- stored(instance, key) do
      wanted = if ids == :all, do: nil, else: MapSet.new(ids)

      ops =
        for %{"id" => id, "read" => false} <- all,
            wanted == nil or id in wanted,
            do: %{"op" => "set", "path" => ["items", id, "read"], "value" => true}

      commit(instance, key, ops)
    end
  end

  @doc false
  # Marks read the items of events the agent heard in the room (the
  # wait_for_events tool): it was there to hear them.
  @spec heard(atom(), String.t(), [Event.t()]) :: :ok | {:error, term()}
  def heard(_instance, _key, []), do: :ok

  def heard(instance, key, events) do
    heard = MapSet.new(events, &{&1.room, &1.data[:comment]})

    with {:ok, all} <- stored(instance, key) do
      ids =
        for %{"room" => room, "data" => data, "id" => id} <- all,
            is_binary(data["comment"]) and {room, data["comment"]} in heard,
            do: id

      mark_read(instance, key, ids)
    end
  end

  defp stored(instance, key) do
    with {:ok, pid} <- Documents.open(instance, document(key)),
         {:ok, snapshot} <- Authority.snapshot(pid),
         do: {:ok, List.wrap(snapshot["state"]["items"])}
  end

  defp commit(_instance, _key, []), do: :ok

  defp commit(instance, key, ops) do
    case Issho.transact(instance, document(key), ops, author: "issho") do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  # Puts an event in the inbox of each it mentions, but its author's, and
  # wakes them, in a process of its own: the caller (a document's
  # authority) does not wait.
  @spec deliver(Config.t(), Event.t()) :: :ok
  def deliver(%Config{} = config, %Event{} = event) do
    case mentioned(event) do
      [] ->
        :ok

      keys ->
        {:ok, _pid} =
          Task.Supervisor.start_child(Config.child_name(config.name, Tasks), fn ->
            Enum.each(keys, &put(config, &1, event))
          end)

        :ok
    end
  end

  # A thread's first comment is its own event too: the inbox has the comment.
  @not_said ["thread.created", "comment.edited"]

  defp mentioned(%Event{name: name}) when name in @not_said, do: []

  defp mentioned(%Event{data: data, by: by}) do
    author = by && by.key

    (data[:mentions] || data["mentions"])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != author))
    |> Enum.uniq()
  end

  defp put(config, key, event) do
    item =
      event
      |> Event.to_map()
      |> Map.merge(%{"id" => Issho.Transaction.id(), "read" => false})

    with {:ok, all} <- stored(config.name, key),
         drop = Enum.take(all, max(length(all) + 1 - @kept, 0)),
         ops = [%{"op" => "insert", "path" => ["items"], "value" => item} | deletes(drop)],
         :ok <- commit(config.name, key, ops) do
      wake(config, key, item)
      nudge()
    else
      {:error, reason} ->
        Logger.error("Issho: no inbox item for #{key}: #{inspect(reason)}")
    end
  end

  defp deletes(items),
    do: for(%{"id" => id} <- items, do: %{"op" => "delete", "path" => ["items", id]})

  defp wake(%Config{on_mention: nil}, _key, _item), do: :ok

  defp wake(%Config{on_mention: hook}, key, item) do
    case hook do
      {module, function} -> apply(module, function, [key, item])
      function when is_function(function, 2) -> function.(key, item)
    end
  rescue
    error ->
      Logger.error(
        "Issho: the :on_mention of #{key} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )
  end

  # The connected MCP clients hear that their inbox changed. Issho.MCP is
  # there only with Sake.
  defp nudge do
    if Code.ensure_loaded?(Issho.MCP), do: Issho.MCP.inbox_changed()
  end
end
