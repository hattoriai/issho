defmodule Issho.Store.None do
  @moduledoc """
  No store: a document that lasts as long as its authority, and starts
  again from its initial content when the next one opens it.

  For documents whose truth is elsewhere: an app that saves each change in
  its own tables from a transaction hook (`:on_transaction`, see
  `Issho.Documents.open/4`), and gives its current data as the initial
  content. A document names it with `store: :none` in its spec.
  """

  @behaviour Issho.Store

  @impl true
  def load(_context, _id), do: {:ok, nil}

  @impl true
  def save(_context, _id, _expected, _document, _content), do: :ok
end
