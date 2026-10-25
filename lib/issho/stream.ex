defmodule Issho.Stream do
  @moduledoc """
  A stream of a room, as it is now (`Issho.Streams`): what it is, whom it
  is for, who writes it, where it is, its state and what it holds so far.

    * `:id`: the stream's id, unique in the cluster.
    * `:room`: the room it is in.
    * `:kind`: what it is, in the app's or the component's words
      (`"summary"`, `"suggestion"`, `"log"`); Issho does not read it.
    * `:for`: who sees it: a key (a person's: theirs, and their agents'),
      `:room` (everyone who may read the room) or `:policy` (whomever the
      policy allows `:read_stream`).
    * `:by`: who writes it, an `Issho.Identity`, or `nil`.
    * `:place`: where it is, a place of a document of the room
      (`Issho.Place`), or `nil`.
    * `:meta`: the app's own, a map Issho keeps and sends.
    * `:state`: `:writing`, `:finished`, `:failed` or `:closed`.
    * `:outcome`: why it failed (`:failed`), or how it was closed
      (`:closed`): `"accepted"`, `"rejected"`, `"stopped"`, the app's own.
    * `:content`: what was written so far, a binary.
    * `:size`: its bytes.
    * `:started_at`: when it began, a `DateTime`.
    * `:pid`: its process, which `Issho.Streams.append/2` and the others
      write to.
  """

  @enforce_keys [:id, :room, :for, :pid]
  defstruct [
    :id,
    :instance,
    :room,
    :kind,
    :for,
    :by,
    :place,
    :outcome,
    :started_at,
    :pid,
    meta: %{},
    state: :writing,
    content: "",
    size: 0
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          instance: atom(),
          room: String.t(),
          kind: String.t() | nil,
          for: String.t() | :room | :policy,
          by: Issho.Identity.t() | nil,
          place: map() | nil,
          meta: map(),
          state: :writing | :finished | :failed | :closed,
          outcome: String.t() | nil,
          content: binary(),
          size: non_neg_integer(),
          started_at: DateTime.t(),
          pid: pid()
        }

  @doc "The id of the request it answers (`Issho.Requests`), from its meta, or `nil`."
  @spec request(t()) :: String.t() | nil
  def request(%__MODULE__{meta: meta}), do: meta[:request] || meta["request"]

  @doc """
  The stream as JSON (string keys, the time in ISO 8601), for a model or a
  browser: who writes it is their public identity.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = stream) do
    %{
      "id" => stream.id,
      "room" => stream.room,
      "kind" => stream.kind,
      "for" => if(is_atom(stream.for), do: Atom.to_string(stream.for), else: stream.for),
      "by" => stream.by && Map.take(Issho.Identity.public(stream.by), ["key", "name", "kind"]),
      "place" => stream.place,
      "meta" => stream.meta,
      "state" => Atom.to_string(stream.state),
      "outcome" => stream.outcome,
      "content" => stream.content,
      "started_at" => DateTime.to_iso8601(stream.started_at)
    }
  end
end
