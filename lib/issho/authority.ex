defmodule Issho.Authority do
  @moduledoc """
  The one process that orders a document's changes, across every node of
  a cluster.

  It loads the document from the store (or builds it from the initial
  content your policy gives), and for each transaction:

    1. checks the envelope (`Issho.Transaction`) and its receipt: a retry
       of an accepted transaction gets its revision again, and changes
       nothing;
    2. applies the operations with the document's engine, all or none;
    3. validates the result (`c:Issho.Engine.validate/2`);
    4. saves the document and its content, comparing the stored version;
    5. only then answers the author and broadcasts the transaction.

  The stored document is the engine's state with Issho's envelope: the
  engine's name and version, an epoch, a revision, the state the epoch
  began with, a journal of the accepted transactions, and their receipts.
  The journal can rebuild any revision of the epoch (`content_at/3`), so a
  form can publish exactly the revision a person saw. (An upgraded document
  that kept no journal rebuilds the revisions from its upgrade on.)

  A store that answers `{:error, :conflict}` means another process saved
  meanwhile (a node that lost touch with the cluster): this one stops, and
  the next open loads the newer document.

  When no session has used the document for the instance's `:ttl` (30
  seconds), the authority stops; the document stays in the store.

  Start an authority with `Issho.Documents.open/3`, not directly.
  """

  use GenServer, restart: :temporary

  alias Issho.{Config, Engine, Transaction}

  require Logger

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Adds a session (a channel, an agent) that uses the document; the
  authority stays while one does. Returns the document as a browser
  receives it, and the document's engine.
  """
  @spec join(GenServer.server(), pid()) :: {:ok, map(), module()}
  def join(server, pid), do: GenServer.call(server, {:join, pid})

  @doc "Takes back a session that no longer uses the document, as if its process had ended."
  @spec leave(GenServer.server(), pid()) :: :ok
  def leave(server, pid), do: GenServer.cast(server, {:leave, pid})

  @doc "The document as a browser receives it: epoch, revision and the engine's snapshot."
  @spec snapshot(GenServer.server()) :: {:ok, map()}
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc """
  Commits a transaction of the actor `author` (its key). Gives
  `{:ok, %{"id" => id, "revision" => revision}}`, with `"duplicate" =>
  true` for a retry, or `{:error, reason}`.
  """
  @spec commit(GenServer.server(), Transaction.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def commit(server, transaction, author),
    do: GenServer.call(server, {:commit, transaction, author}, 15_000)

  @doc "Which of these transaction ids the author already has accepted, after a reconnect."
  @spec accepted(GenServer.server(), [String.t()], String.t()) :: [String.t()]
  def accepted(server, ids, author), do: GenServer.call(server, {:accepted, ids, author})

  @doc "The content of the current revision, with its epoch and revision."
  @spec content(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def content(server), do: GenServer.call(server, :content)

  @doc "The content of an accepted revision of the epoch."
  @spec content_at(GenServer.server(), String.t(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def content_at(server, epoch, revision),
    do: GenServer.call(server, {:content_at, epoch, revision})

  @doc false
  @spec topic(String.t()) :: String.t()
  def topic(document_id), do: "issho:document:" <> document_id

  # Server

  @impl true
  def init(opts) do
    config = Config.get(Keyword.fetch!(opts, :instance))
    id = Keyword.fetch!(opts, :document_id)
    spec = Keyword.fetch!(opts, :spec)
    engine = Map.fetch!(spec, :engine)
    engine_opts = Map.get(spec, :opts, [])
    {store, context} = store(Map.get(spec, :store), config.store)

    with {:ok, loaded} <- store.load(context, id),
         {stored, spec} = initial(loaded, spec),
         {:ok, document} <- document(stored, engine, spec, engine_opts),
         {:ok, content} <- Engine.validate(engine, document["state"], engine_opts),
         :ok <- first_save(stored, store, context, id, document, content) do
      {:ok,
       %{
         config: config,
         id: id,
         engine: engine,
         opts: engine_opts,
         store: store,
         context: context,
         hook: Map.get(spec, :on_transaction),
         document: document,
         content: content,
         members: %{},
         timer: Process.send_after(self(), :expire, config.ttl)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # A store that has the content but no document yet (your app's own
  # table, before anyone opened it together) gives the initial content.
  defp initial({:initial, content}, spec), do: {nil, Map.put(spec, :initial, content)}
  defp initial(stored, spec), do: {stored, spec}

  defp document(nil, engine, spec, opts) do
    with {:ok, state} <- engine.init(Map.get(spec, :initial), opts) do
      {:ok,
       %{
         "engine" => engine.name(),
         "engine_version" => engine.version(),
         "epoch" => Transaction.id(),
         "revision" => 0,
         "state" => state,
         "initial" => state,
         "journal" => [],
         "receipts" => %{}
       }}
    end
  end

  defp document(%{"engine" => name, "engine_version" => version} = stored, engine, _spec, _opts)
       when is_binary(name) do
    cond do
      name == engine.name() and version == engine.version() -> {:ok, stored}
      Engine.upgrades?(engine) -> upgrade(engine, stored)
      true -> {:error, {:engine_mismatch, name, version}}
    end
  end

  defp document(stored, engine, _spec, _opts) do
    if Engine.upgrades?(engine),
      do: upgrade(engine, stored),
      else: {:error, :unsupported_document}
  end

  # A stored document of another engine version, or from before Issho (a
  # library's own format): the engine's upgrade/1 gives its state, epoch
  # and revision, and its journal and receipts if it kept them.
  defp upgrade(engine, stored) do
    case engine.upgrade(stored) do
      {:ok, %{"state" => state, "epoch" => epoch, "revision" => revision} = upgraded}
      when is_binary(epoch) and is_integer(revision) ->
        {initial, journal} = history(upgraded, state)

        {:ok,
         %{
           "engine" => engine.name(),
           "engine_version" => engine.version(),
           "epoch" => epoch,
           "revision" => revision,
           "state" => state,
           "initial" => initial,
           "base" => revision - length(journal),
           "journal" => journal,
           "receipts" => Map.get(upgraded, "receipts", %{})
         }}

      {:error, _reason} = error ->
        error

      other ->
        raise ArgumentError, "#{inspect(engine)}.upgrade/1 returned #{inspect(other)}"
    end
  end

  # The journal an upgraded document kept, from the state it began with;
  # without one, its journal begins at the revision it has.
  defp history(%{"initial" => initial, "journal" => journal}, _state) when is_list(journal),
    do: {initial, journal}

  defp history(_upgraded, state), do: {state, []}

  defp store(:none, _default), do: {Issho.Store.None, nil}
  defp store({module, _context} = store, _default) when is_atom(module), do: store
  defp store(nil, {module, _context} = store) when is_atom(module), do: store

  defp store(nil, nil),
    do:
      raise(ArgumentError, "Issho needs a :store for documents, or `store: :none` in their spec")

  defp first_save(nil, store, context, id, document, content),
    do: store.save(context, id, nil, document, content)

  defp first_save(_stored, _store, _context, _id, _document, _content), do: :ok

  @impl true
  def handle_call({:join, pid}, _from, state) do
    state =
      if Map.has_key?(state.members, pid),
        do: state,
        else: %{state | members: Map.put(state.members, pid, Process.monitor(pid))}

    {:reply, {:ok, snapshot_of(state), state.engine}, cancel_timer(state)}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, snapshot_of(state)}, state}

  def handle_call(:content, _from, state) do
    %{"epoch" => epoch, "revision" => revision} = state.document

    {:reply, {:ok, %{"epoch" => epoch, "revision" => revision, "content" => state.content}},
     state}
  end

  def handle_call({:content_at, epoch, revision}, _from, state) do
    {:reply, content_at_revision(state, epoch, revision), state}
  end

  def handle_call({:accepted, ids, author}, _from, state) do
    receipts = state.document["receipts"]

    accepted =
      for id <- List.wrap(ids), is_binary(id), get_in(receipts, [id, "author"]) == author, do: id

    {:reply, accepted, state}
  end

  def handle_call({:commit, transaction, author}, _from, state) do
    started = System.monotonic_time()
    result = commit_transaction(state, transaction, author)

    :telemetry.execute(
      [:issho, :transaction, :commit],
      %{duration: System.monotonic_time() - started},
      %{instance: state.config.name, document: state.id, author: author, result: elem(result, 0)}
    )

    case result do
      {:ok, reply, state} -> {:reply, {:ok, reply}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:stop, reason, state} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  defp commit_transaction(state, transaction, author) do
    document = state.document

    with :ok <- Transaction.check(transaction, document["epoch"], document["revision"]),
         digest = Transaction.digest(transaction, author),
         :new <- receipt(document, transaction["id"], digest),
         {:ok, engine_state} <-
           state.engine.apply(document["state"], transaction["ops"], [
             {:author, author} | state.opts
           ]),
         {:ok, content} <- Engine.validate(state.engine, engine_state, state.opts),
         revision = document["revision"] + 1,
         :ok <- hook(state, transaction, author, engine_state, revision) do
      event =
        transaction
        |> Map.take(["id", "epoch", "base_revision", "ops"])
        |> Map.merge(%{"revision" => revision, "author" => author})

      next =
        document
        |> Map.merge(%{"state" => engine_state, "revision" => revision})
        |> Map.update!("journal", &(&1 ++ [event]))
        |> put_in(["receipts", transaction["id"]], %{
          "digest" => digest,
          "revision" => revision,
          "author" => author
        })

      persist(state, next, content, event)
    else
      {:duplicate, revision} ->
        {:ok, %{"id" => transaction["id"], "revision" => revision, "duplicate" => true}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # The document's transaction hook, once per accepted transaction, before
  # it is saved: the app can save it in its own tables, or refuse it.
  defp hook(%{hook: nil}, _transaction, _author, _after, _revision), do: :ok

  defp hook(state, transaction, author, after_state, revision) do
    context = %{
      document: state.id,
      author: author,
      revision: revision,
      before: state.document["state"],
      after: after_state
    }

    case state.hook.(transaction["ops"], context) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> raise ArgumentError, "an :on_transaction hook returned #{inspect(other)}"
    end
  rescue
    error ->
      Logger.error(
        "Issho: the :on_transaction hook of #{state.id} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, :hook_failed}
  end

  defp receipt(document, id, digest) do
    case document["receipts"][id] do
      nil -> :new
      %{"digest" => ^digest, "revision" => revision} -> {:duplicate, revision}
      _ -> {:error, :id_reused}
    end
  end

  defp persist(state, next, content, event) do
    expected = {state.document["epoch"], state.document["revision"]}

    result =
      if :erlang.external_size(next) <= state.config.max_document_bytes,
        do: state.store.save(state.context, state.id, expected, next, content),
        else: {:error, :document_too_large}

    case result do
      :ok ->
        Phoenix.PubSub.broadcast(
          state.config.pubsub,
          topic(state.id),
          {Issho, :transaction, state.id, event}
        )

        {:ok, %{"id" => event["id"], "revision" => event["revision"]},
         %{state | document: next, content: content}}

      {:error, :conflict} ->
        Logger.warning("Issho: a newer #{state.id} was saved elsewhere; this authority stops")
        {:stop, :stale_authority, state}

      {:error, :document_too_large} ->
        {:error, :document_too_large, state}

      {:error, reason} ->
        {:error, {:storage, reason}, state}
    end
  end

  defp content_at_revision(state, epoch, revision) do
    document = state.document
    base = Map.get(document, "base", 0)

    if epoch == document["epoch"] and is_integer(revision) and revision >= base and
         revision <= document["revision"] do
      # Each transaction as it was accepted: an engine may limit the
      # operations of one.
      events = Enum.take(document["journal"], revision - base)

      with {:ok, engine_state} <- replay(state, document["initial"], events),
           do: Engine.validate(state.engine, engine_state, state.opts)
    else
      {:error, :unknown_revision}
    end
  end

  defp replay(_state, engine_state, []), do: {:ok, engine_state}

  defp replay(state, engine_state, [event | rest]) do
    opts = [{:author, event["author"]} | state.opts]

    with {:ok, next} <- state.engine.apply(engine_state, event["ops"], opts),
         do: replay(state, next, rest)
  end

  defp snapshot_of(state) do
    %{
      "id" => state.id,
      "engine" => state.document["engine"],
      "epoch" => state.document["epoch"],
      "revision" => state.document["revision"],
      "state" => Engine.snapshot(state.engine, state.document["state"])
    }
  end

  @impl true
  def handle_cast({:leave, pid}, state) do
    case Map.pop(state.members, pid) do
      {nil, _members} ->
        {:noreply, state}

      {ref, members} ->
        Process.demonitor(ref, [:flush])
        {:noreply, member_gone(%{state | members: members})}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, member_gone(%{state | members: Map.delete(state.members, pid)})}

  def handle_info(:expire, %{members: members} = state) when map_size(members) == 0,
    do: {:stop, :normal, state}

  def handle_info(:expire, state), do: {:noreply, state}

  # The last session gone: the document goes after the TTL, unless one comes.
  defp member_gone(%{members: members} = state) when map_size(members) == 0,
    do: %{state | timer: Process.send_after(self(), :expire, state.config.ttl)}

  defp member_gone(state), do: state

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end
end
