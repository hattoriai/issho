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
  The authority of a document, started if it is not running anywhere. The
  first open on a node asks the policy what the document is
  (`c:Issho.Policy.document/2`), with the identity of whoever opens it.
  """
  @spec open(atom(), String.t(), Identity.t() | nil) :: {:ok, pid()} | {:error, term()}
  def open(instance, document_id, identity \\ nil) when is_binary(document_id) do
    config = Config.get(instance)
    name = name(config, document_id)

    case GenServer.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> start(config, document_id, name, identity)
    end
  end

  defp start(config, document_id, name, identity) do
    with {:ok, spec} <- spec(config.policy, identity, document_id) do
      child = {Authority, instance: config.name, document_id: document_id, spec: spec, name: name}

      case DynamicSupervisor.start_child(Config.child_name(config.name, Documents), child) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
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
