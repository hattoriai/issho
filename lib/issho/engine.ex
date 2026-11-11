defmodule Issho.Engine do
  @moduledoc """
  The model of a document: how its operations apply. Each binding brings
  one (Kotoba's text, Hakushi's graph, a map for shared assigns), and the
  authority (`Issho.Authority`) runs it.

  An engine is pure: no I/O, no clock, no randomness. The same operations
  on the same state give the same state on every node, in a test, and in
  the browser's twin of the engine. That is also what lets an engine move
  to a NIF or to WebAssembly unchanged.

  Its state is a map of strings, numbers, booleans, `nil`, lists and maps
  with string keys (JSON) when browsers hold the document (they receive
  it, and run the engine's twin) or the store saves JSON. A document only
  LiveViews and agents hold, kept by no store or a store of terms, can be
  any Erlang term: a struct of your own.

  Everything outside the engine treats operations as opaque: the authority,
  the store, receipts, the journal and the offline queue see only a
  transaction's id, its base revision and its author.

  ## Callbacks

    * `c:name/0` and `c:version/0` tag every stored state, so that a
      document can move to another engine, or a new version, on its own
      schedule.
    * `c:init/2` builds a state from the initial content your policy gives
      (`c:Issho.Policy.document/2`).
    * `c:apply/3` applies one transaction's operations, all or none.
    * `c:validate/2` checks a state and gives its content: what your app
      publishes and the store keeps beside the state (a rendered HTML, a
      graph). Without it, the content is the state.
    * `c:snapshot/1` is what a browser receives when it opens the
      document. Without it, the state.
    * `c:upgrade/1` takes a stored document of another version of the
      engine, or one saved before Issho in a library's own format, and
      gives its `"state"`, `"epoch"` and `"revision"`, and its
      `"receipts"` if it kept them. With an `"initial"` state and a
      `"journal"` of the transactions since, earlier revisions can be
      rebuilt. Keep the epoch and revision the store has, so that the
      first save after the upgrade finds the version it expects.
      The upgraded document is saved with the next transaction; until
      then the store keeps it as it was. Without it, such a document does
      not open.
    * `c:compact/2` gives the state without what only past operations
      need: a text's deleted characters, kept as anchors for changes made
      before they were deleted. With the instance's `:compact`, an idle
      document is saved compacted, as a new epoch that continues the last
      (see `Issho.Authority`). Without it, a document is never compacted.
  """

  @type state :: map()
  @type operation :: map()

  @doc ~S|The engine's name, stored with every state: `"map"`, `"kotoba"`.|
  @callback name() :: String.t()

  @doc "The version of the engine's state and operations."
  @callback version() :: pos_integer()

  @doc "A state from the initial content of a document."
  @callback init(initial :: term(), opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  The state after a transaction's operations, all or none. `opts` has the
  engine's options and `:author`, the key of the actor who made it.
  """
  @callback apply(state(), [operation()], opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc "Checks a state and gives its content."
  @callback validate(state(), opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc "The state a browser receives when it opens the document."
  @callback snapshot(state()) :: map()

  @doc "A stored document of another version, or format, as this engine's."
  @callback upgrade(stored :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  The state without what only past operations need. Three promises, which
  the authority relies on:

    1. The same content: `c:validate/2` gives the same for both. The
       authority checks it, and keeps the old state when it differs.
    2. Everything that remains keeps its identity (a node's id, a
       character's id, a list item's id), so places, comments and anchors
       that name it still find it.
    3. An operation made on the state before compaction (a transaction of
       the epoch it continues, sent by a browser that was offline) either
       applies as it would have, or names something that went and is
       refused by `c:apply/3`: never applied somewhere else.

  Pure, like the rest of the engine. Give the state unchanged when there
  is nothing to drop; the authority compares sizes.
  """
  @callback compact(state(), opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @optional_callbacks validate: 2, snapshot: 1, upgrade: 1, compact: 2

  @doc false
  @spec validate(module(), state(), keyword()) :: {:ok, term()} | {:error, term()}
  def validate(engine, state, opts) do
    if exports?(engine, :validate, 2), do: engine.validate(state, opts), else: {:ok, state}
  end

  @doc false
  @spec snapshot(module(), state()) :: map()
  def snapshot(engine, state) do
    if exports?(engine, :snapshot, 1), do: engine.snapshot(state), else: state
  end

  @doc false
  @spec upgrades?(module()) :: boolean()
  def upgrades?(engine), do: exports?(engine, :upgrade, 1)

  @doc false
  @spec compacts?(module()) :: boolean()
  def compacts?(engine), do: exports?(engine, :compact, 2)

  defp exports?(module, name, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, name, arity)
end
