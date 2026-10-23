defmodule Issho.Policy do
  @moduledoc ~S"""
  Your app's answer to "may this actor do this here?", and to "what is
  this document?". Issho has no roles and no user model: it asks, and your
  app answers with whatever it already uses.

      defmodule MyApp.Collaboration do
        @behaviour Issho.Policy

        @impl true
        def authorize(%Issho.Identity{} = who, "board:" <> id, action) do
          if MyApp.Boards.allowed?(who.claims["user_id"], id, action),
            do: :ok,
            else: {:error, :forbidden}
        end

        @impl true
        def document(_who, "board:" <> id) do
          board = MyApp.Boards.get!(id)
          {:ok, %{engine: Issho.Engine.Map, initial: board.content}}
        end
      end

  ## Actions

  `authorize/3` gets the room (the topic, such as `"board:42"`) and one of:

    * `:join`: to enter the room, see its people and their places;
    * `:read`: to receive its documents and their changes, asked again
      for the changes others make, so that a person whose access you take
      away stops receiving them;
    * `:write`: to change its documents;
    * `:comment`: to change its comments (`Issho.Comments`): start a
      thread, reply, react, resolve. A reader (a grant with `can: :read`)
      may comment when you allow it, so a commenter is between a reader
      and a writer. A policy that answers `{:error, _}` for actions it
      does not know lets no one comment until it says `:comment`;
    * `:lock`: to hold an advisory lock on a place;
    * `:interrupt`: to pause, resume or stop an agent at work in the room
      (`Issho.Work`) that acts for someone else; the person an agent acts
      for may always.

  A component that keeps its data outside Issho's documents (a grid of
  your database, which writes it itself) asks too, with
  `Issho.Participant.authorize/2`.

  Issho asks on join and on every message in both directions, so keep it
  fast: put what it needs in the identity's `claims` when you sign the
  token (`Issho.Token.sign/4`), or cache.

  ## Documents

  `document/2` says what a document is when it opens for the first time on
  a node: its engine (`Issho.Engine`), its initial content from your
  server (a browser never seeds a document), and the engine's options.
  What it says is the document, whoever opens it first: a page, the same
  document embedded in another page, an agent with no browser at all. A
  component's own spec (`Issho.Live.open/3`'s `:spec`) is used only for a
  document `document/2` does not know (it answers `{:error, _}`), so
  define here a document that opens in more than one place. A
  room's documents are the room itself (`"board:42"`) and paths under it
  (`"board:42/n7/body"`), so the nested documents of a canvas share the
  room's people and authorization.
  """

  alias Issho.Identity

  @type action :: :join | :read | :write | :comment | :lock | :interrupt

  @typedoc """
  What a document is: its engine, its initial content (given to the
  engine's `c:Issho.Engine.init/2` when the store has nothing), and the
  engine's options.
  """
  @type document :: %{
          required(:engine) => module(),
          optional(:initial) => term(),
          optional(:opts) => keyword()
        }

  @doc "Whether the actor may do the action in the room."
  @callback authorize(Identity.t(), room :: String.t(), action()) :: :ok | {:error, term()}

  @doc "What a document is, when it opens for the first time on a node."
  @callback document(Identity.t() | nil, document_id :: String.t()) ::
              {:ok, document()} | {:error, term()}

  @optional_callbacks document: 2

  @doc false
  @spec authorize(module(), Identity.t(), String.t(), action()) :: :ok | {:error, term()}
  def authorize(policy, identity, room, action) do
    case policy.authorize(identity, room, action) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> raise ArgumentError, "#{inspect(policy)}.authorize/3 returned #{inspect(other)}"
    end
  end

  @doc """
  The room of a document: the part of its id before the first `"/"`, or
  the whole id. The documents of a page share a room (`"notebook:7/cell-1"`,
  `"notebook:7/cell-2"`), and with it its people and their places.

      iex> Issho.Policy.room("notebook:7/cell-1")
      "notebook:7"
      iex> Issho.Policy.room("post:42")
      "post:42"
  """
  @spec room(String.t()) :: String.t()
  def room(document_id) do
    document_id |> String.split("/", parts: 2) |> hd()
  end
end
