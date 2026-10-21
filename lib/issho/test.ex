defmodule Issho.Test do
  @moduledoc ~S"""
  Helpers for testing an app or a binding with Issho, in ExUnit.

      setup do
        instance = Issho.Test.start!(policy: MyApp.Collaboration)
        %{instance: instance}
      end

      test "an agent drafts a title", %{instance: instance} do
        {:ok, agent} = Issho.join_as(instance, %{id: "agent:1", kind: :agent}, "board:1")
        {:ok, _} = Issho.Participant.open(agent, "board:1")
        {:ok, _} = Issho.Participant.transact(agent, "board:1", ops)
        assert Issho.Test.replays?(instance, "board:1")
      end

  `start!/1` starts an isolated instance for the test: its own PubSub, a
  store in memory, quick awareness frames, and no `Issho.Presence` unless
  you ask (`presence: true`; only one runs on a node).
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Issho.{Authority, Documents}

  @doc """
  Starts an isolated instance under the test's supervisor and gives its
  name. Options: `:policy` (required), and any option of `Issho`.
  """
  @spec start!(keyword()) :: atom()
  def start!(opts) do
    id = System.unique_integer([:positive])
    name = Keyword.get(opts, :name, :"Elixir.Issho.Test.Instance#{id}")
    pubsub = Keyword.get_lazy(opts, :pubsub, fn -> start_pubsub!(id) end)
    store = Module.concat(name, Store)

    start_supervised!({Issho.Store.Memory, name: store})

    start_supervised!(
      {Issho,
       Keyword.merge(
         [
           name: name,
           pubsub: pubsub,
           secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
           store: {Issho.Store.Memory, store},
           presence: false,
           ttl: 1_000,
           awareness_interval: 5,
           awareness_full_every: 20
         ],
         Keyword.drop(opts, [:name, :pubsub])
       )}
    )

    name
  end

  defp start_pubsub!(id) do
    name = :"Elixir.Issho.Test.PubSub#{id}"
    start_supervised!({Phoenix.PubSub, name: name})
    name
  end

  @doc """
  Whether replaying a document's journal from the start of its epoch gives
  its current content: the engine is deterministic, and nothing changed
  the state outside a transaction. A conformance check for engines.
  """
  @spec replays?(atom(), String.t()) :: boolean()
  def replays?(instance, document_id) do
    {:ok, pid} = Documents.open(instance, document_id)

    {:ok, %{"epoch" => epoch, "revision" => revision, "content" => content}} =
      Authority.content(pid)

    Authority.content_at(pid, epoch, revision) == {:ok, content}
  end
end
