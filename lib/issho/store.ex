defmodule Issho.Store do
  @moduledoc """
  Where documents last. Your app implements it on its database;
  `Issho.Store.Memory` is for development and tests.

  `c:load/2` gives the document as last saved, or `nil` for one that has
  never been saved. A store on your app's own table, which has the
  content before anyone opens it together (a post's body), gives
  `{:initial, content}`: the document starts from it, in place of the
  spec's `:initial`, and is saved at once, with `expected` `nil`.

  `c:save/5` must compare the stored `{epoch, revision}` with `expected`
  and save the document and its content together, in one atomic write,
  and answer `{:error, :conflict}` to a stale writer. The
  authority confirms an edit to its author only after `save/5` answers
  `:ok`, so answering before the write is durable breaks that promise.

  The document is a map of JSON values (save it as a JSON or map column).
  The content is what the engine's `c:Issho.Engine.validate/2` gave: keep
  it beside the document for your app to read and publish.

  The context is your app's, given with the store: a repo, an options map.

      {Issho, name: MyApp.Issho, store: {MyApp.CollabStore, MyApp.Repo}, ...}
  """

  @type document :: map()
  @type expected :: {epoch :: String.t(), revision :: non_neg_integer()} | nil

  @doc "The document as last saved, `nil`, or `{:initial, content}` to start one from."
  @callback load(context :: term(), document_id :: String.t()) ::
              {:ok, document() | nil | {:initial, term()}} | {:error, term()}

  @doc "Saves the document and its content, if the stored version is `expected`."
  @callback save(
              context :: term(),
              document_id :: String.t(),
              expected(),
              document(),
              content :: term()
            ) :: :ok | {:error, :conflict} | {:error, term()}
end
