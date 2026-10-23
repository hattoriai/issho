defmodule Issho.Documents do
  @moduledoc """
  The authorities (`Issho.Authority`) of an Issho instance: one for each
  open document, found by name on every node of a cluster.

  The registry is `:global` unless the instance's `:registry` is a module
  with `name(instance, document_id)`, which returns a `GenServer` name
  (a `{:via, ...}` tuple for Horde or a partitioned registry).
  """

  use DynamicSupervisor

  alias Issho.{Authority, Config, Identity, Policy}

  @doc false
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  The authority of a document, started if it is not running anywhere.

  What the document is (its spec) comes from the policy's
  `c:Issho.Policy.document/2`, asked with the identity of whoever opens it
  first, whoever that is: a page, an embed of the same document in another
  page, an agent. A `:spec` given by your server's own code (a component
  that holds the document's initial content and its hook) is what the
  document is only when the policy does not say (it answers
  `{:error, _}`, or has no `document/2`). Defined in the policy, a
  document is the same wherever it opens first; given by components, the
  first to open it gives its spec, and the others' are not used. A browser
  never gives a spec.

  A spec is a map:

    * `:engine` (required): the document's `Issho.Engine` or binding.
    * `:initial`: the initial content, when the store has nothing.
    * `:opts`: the engine's options.
    * `:store`: `{module, context}`, or `:none` for a document that lasts
      as long as its authority (`Issho.Store.None`); the instance's store
      unless given.
    * `:on_transaction`: a function of the operations and a context
      (`:document`, `:author`, `:revision`, and the state `:before` and
      `:after`), run once for each accepted transaction, after the engine
      and before it is saved and confirmed. It answers `:ok` (or `{:ok,
      anything}`), or `{:error, reason}` to refuse the transaction: the
      place to save each change in your own tables.
    * `:events`: a function of the operations and the same context, run
      once for each accepted transaction after it is saved, which gives
      the events it makes happen (`[{name, data}]`), emitted in the room
      (`Issho.Events`) with the document and its author: a card that lands
      on a frame, a comment.
  """
  @spec open(atom(), String.t(), Identity.t() | nil, keyword()) :: {:ok, pid()} | {:error, term()}
  def open(instance, document_id, identity \\ nil, opts \\ []) when is_binary(document_id) do
    config = Config.get(instance)
    name = name(config, document_id)

    case GenServer.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> start(config, document_id, name, identity, opts[:spec])
    end
  end

  @doc "The authority of a document if it is running, on any node, or `nil`."
  @spec whereis(atom(), String.t()) :: pid() | nil
  def whereis(instance, document_id) when is_binary(document_id) do
    case GenServer.whereis(name(Config.get(instance), document_id)) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp start(config, document_id, name, identity, given) do
    with {:ok, spec} <- given_or_policy(given, config.policy, identity, document_id) do
      child = {Authority, instance: config.name, document_id: document_id, spec: spec, name: name}

      case DynamicSupervisor.start_child(Config.child_name(config.name, Documents), child) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Issho's own documents of a room (its comments) are Issho's, whatever
  # the policy says; else the policy's, when it says what the document
  # is; else the spec given.
  defp given_or_policy(given, policy, identity, document_id) do
    case {own(document_id) || spec(policy, identity, document_id), given} do
      {{:ok, spec}, _given} -> {:ok, spec}
      {{:error, _reason}, %{engine: engine} = spec} when is_atom(engine) -> {:ok, spec}
      {{:error, _reason} = error, _given} -> error
    end
  end

  defp own(document_id) do
    if Issho.Comments.document?(document_id), do: {:ok, Issho.Comments.spec()}
  end

  defp spec(policy, identity, document_id) do
    Code.ensure_loaded(policy)

    if function_exported?(policy, :document, 2) do
      case policy.document(identity, document_id) do
        {:ok, %{engine: engine} = spec} when is_atom(engine) -> {:ok, spec}
        {:error, _reason} = error -> error
        other -> raise ArgumentError, "#{inspect(policy)}.document/2 returned #{inspect(other)}"
      end
    else
      {:error, :no_documents}
    end
  end

  @doc false
  # Every document of a room is the room or a path under it.
  @spec in_room?(String.t(), String.t()) :: boolean()
  def in_room?(document_id, room), do: Policy.room(document_id) == room

  defp name(%Config{registry: :global, name: instance}, document_id),
    do: {:global, {Authority, instance, document_id}}

  defp name(%Config{registry: registry, name: instance}, document_id),
    do: registry.name(instance, document_id)
end
