defmodule Issho do
  @moduledoc ~S"""
  Collaboration for Phoenix: one engine for people and agents working
  together live, under every component on a page.

  Start an instance in your supervision tree, after your PubSub:

      {Issho,
       name: MyApp.Issho,
       pubsub: MyApp.PubSub,
       endpoint: MyAppWeb.Endpoint,
       policy: MyApp.Collaboration,
       store: {MyApp.CollabStore, MyApp.Repo}}

  ## Options

    * `:name` (required): the instance's name, given to every call.
    * `:pubsub` (required): your app's `Phoenix.PubSub`.
    * `:policy` (required): your `Issho.Policy`, which authorizes every
      action and says what each document is.
    * `:endpoint` or `:secret_key_base`: to sign join tokens.
    * `:store`: `{module, context}`, an `Issho.Store` for documents.
    * `:registry`: `:global` (the default) or a module with
      `name(instance, document_id)`, for the documents' authorities.
    * `:presence`: whether this instance starts `Issho.Presence` (`true`).
    * `:ttl`: how long, in milliseconds, an unused document stays open
      (30 seconds).
    * `:awareness_interval`: milliseconds between awareness frames (50).
    * `:awareness_max_bytes`: the largest awareness state of a session, as
      JSON (64 KB).
    * `:max_document_bytes` (16 MB), `:max_message_bytes` (1 MB) and
      `:token_max_age` (300 seconds).

  See the architecture guide for how the parts fit together.
  """

  use Supervisor

  alias Issho.{Config, Session}

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts an instance. See the options above."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    config = Config.new(opts)
    :ok = Config.put(config)
    Supervisor.start_link(__MODULE__, config, name: Config.child_name(config.name, Supervisor))
  end

  @impl true
  def init(%Config{name: name} = config) do
    presence =
      if config.presence, do: [{Issho.Presence, pubsub_server: config.pubsub}], else: []

    children =
      presence ++
        [
          {Registry, keys: :unique, name: Config.child_name(name, AwarenessRegistry)},
          {DynamicSupervisor,
           strategy: :one_for_one, name: Config.child_name(name, AwarenessSupervisor)},
          {Issho.Documents, name: Config.child_name(name, Documents)},
          {DynamicSupervisor, strategy: :one_for_one, name: Config.child_name(name, Participants)}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Joins a room as an actor from Elixir (an agent, a job), as a browser
  would. Gives an `Issho.Participant`. Options: `:can` (`:write`),
  `:on_behalf_of`, `:claims` and `:notify` (the process that receives the
  room's events, the caller unless given).
  """
  @spec join_as(atom(), Issho.Actor.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def join_as(instance, actor, room, opts \\ []) do
    opts = Keyword.put_new(opts, :notify, self())

    DynamicSupervisor.start_child(
      Config.child_name(instance, Participants),
      %{
        id: Issho.Participant,
        start: {Issho.Participant, :start_link, [{instance, actor, room, opts}]},
        restart: :temporary
      }
    )
  end

  @doc """
  Takes an actor out of a room now, on every node: its sessions end, and
  it receives nothing more. Your app calls it when it takes access away;
  the policy refuses the actor from then on.
  """
  @spec revoke(atom(), String.t(), Issho.Actor.t() | String.t()) :: :ok
  def revoke(instance, room, actor_or_key) do
    key = if is_binary(actor_or_key), do: actor_or_key, else: Issho.Actor.key(actor_or_key)

    Phoenix.PubSub.broadcast(
      Config.get(instance).pubsub,
      Session.room_topic(room),
      {Issho, :revoke, room, key}
    )
  end

  @doc """
  The content of a document's revision, for a form that publishes exactly
  what a person saw: the `epoch` and `revision` the browser posts.
  """
  @spec content(atom(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def content(instance, document_id, epoch, revision) do
    with {:ok, pid} <- Issho.Documents.open(instance, document_id),
         do: Issho.Authority.content_at(pid, epoch, revision)
  end

  @doc """
  Commits operations to a document from your server (a job, an import),
  through the same checks and authority as everyone else's. `author` is
  the key it is recorded under (`"server"` unless given).
  """
  @spec transact(atom(), String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def transact(instance, document_id, ops, opts \\ []) when is_list(ops) do
    with {:ok, pid} <- Issho.Documents.open(instance, document_id),
         {:ok, snapshot} <- Issho.Authority.snapshot(pid) do
      transaction = %{
        "id" => Keyword.get_lazy(opts, :id, &Issho.Transaction.id/0),
        "epoch" => snapshot["epoch"],
        "base_revision" => snapshot["revision"],
        "ops" => ops
      }

      Issho.Authority.commit(pid, transaction, Keyword.get(opts, :author, "server"))
    end
  end
end
