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

  @optional_callbacks validate: 2, snapshot: 1

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

  defp exports?(module, name, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, name, arity)
end
