defmodule Issho.Store.Memory do
  @moduledoc """
  A store in memory, for development and tests. It outlives a document's
  authority, but loses everything when its node stops.

      children = [
        {Issho.Store.Memory, name: MyApp.CollabStore},
        {Issho, name: MyApp.Issho, store: {Issho.Store.Memory, MyApp.CollabStore}, ...}
      ]

  `content/2` reads a document's content as last saved, for tests.
  """

  @behaviour Issho.Store

  use Agent

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts a store. Options: `:name`."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def load(store, id) do
    {:ok, Agent.get(store, &get_in(&1, [id, :document]))}
  end

  @impl true
  def save(store, id, expected, document, content) do
    Agent.get_and_update(store, fn documents ->
      if version(documents[id]) == expected do
        {:ok, Map.put(documents, id, %{document: document, content: content})}
      else
        {{:error, :conflict}, documents}
      end
    end)
  end

  @doc "The content of a document as last saved, or `nil`."
  @spec content(Agent.agent(), String.t()) :: term()
  def content(store, id), do: Agent.get(store, &get_in(&1, [id, :content]))

  defp version(nil), do: nil
  defp version(%{document: document}), do: {document["epoch"], document["revision"]}
end
