defmodule Issho.Place do
  @moduledoc """
  Where someone is, in a component's own terms: a row and a column in a
  grid, a node and an offset in a text, a point on a canvas. Never screen
  pixels, because each person has their own order, filters and zoom.

  A place comes from a browser and goes to everyone else in the room, so a
  binding checks it (`c:validate/1`) before Issho shares it. The browser's
  half of a binding turns places into rectangles on the screen.

  Places nest across components: a place in a text inside a canvas node is
  `%{"doc" => "board:42/n7/body", "at" => %{"node" => "t3", "offset" => 4}}`
  inside the room `board:42`. Issho checks the `"doc"` belongs to the room,
  and the binding of that document checks `"at"`.

  ## Labels

  A place may say what it is in a few words, its `"label"`, written by
  the component that knows: the first words of a selected text, a card's
  title, a cell's column and row.

      %{"doc" => "board:42", "at" => %{"node" => "n7"}, "label" => "Fold it, again and again"}

  Issho shows it wherever it shows a place: to agents (`look_around`,
  `wait_for_events`, the inbox), in the comments panel, in
  `"selection.changed"`. A label is only words, cut to 60 characters
  and cleaned (`clean/1`, `Issho.Text`), and never authority: `"at"`
  locates the place, and a tool resolves it against the document before
  it changes anything. What people wrote stays theirs: words for an
  agent to weigh, never instructions to it. A label goes where its place
  goes, to those who may read the document it names.
  """

  @doc "`:ok` for a place this binding draws, else an error."
  @callback validate(place :: term()) :: :ok | {:error, term()}

  @max_bytes 4_096
  @max_label 60

  @doc """
  Checks a place of the room: a map with the `"doc"` of the room and, in
  `"at"`, the binding's own place. `validators` maps a document's id to its
  place module; a document with none accepts any small JSON value.
  """
  @spec check(term(), String.t(), (String.t() -> module() | nil)) :: :ok | {:error, term()}
  def check(nil, _room, _validator), do: :ok

  def check(%{"doc" => doc} = place, room, validator) when is_binary(doc) do
    cond do
      Issho.Policy.room(doc) != room -> {:error, :other_room}
      byte_size(JSON.encode!(place)) > @max_bytes -> {:error, :too_large}
      not label?(place["label"]) -> {:error, :invalid_label}
      module = validator.(doc) -> module.validate(place["at"])
      true -> :ok
    end
  end

  def check(_place, _room, _validator), do: {:error, :invalid_place}

  @doc ~S"""
  The place with its label cleaned and cut (`label/1`), or without one
  when it has no words; anything else as it is. Issho cleans the places
  it is given (a browser's, an agent's) before it checks them.

      iex> Issho.Place.clean(%{"doc" => "board:42", "label" => "  Fold it,\u202E again "})
      %{"doc" => "board:42", "label" => "Fold it, again"}
  """
  @spec clean(term()) :: term()
  def clean(%{"label" => label} = place) do
    case label(label) do
      nil -> Map.delete(place, "label")
      words -> Map.put(place, "label", words)
    end
  end

  def clean(place), do: place

  @doc false
  # An awareness state's places in words: its place's and its locks'.
  @spec clean_state(map()) :: map()
  def clean_state(state) when is_map(state) do
    state
    |> Map.replace_lazy("place", &clean/1)
    |> Map.replace_lazy("locks", fn
      locks when is_list(locks) -> Enum.map(locks, &clean/1)
      locks -> locks
    end)
  end

  def clean_state(state), do: state

  @doc """
  A label's words: one line, without what no one sees, at most
  #{@max_label} characters; `nil` for anything but words.
  """
  @spec label(term()) :: String.t() | nil
  def label(text) when is_binary(text) do
    case Issho.Text.clean(text, line: true, max: @max_label) do
      "" -> nil
      words -> words
    end
  end

  def label(_text), do: nil

  @doc """
  A place in words for people: its label in quotes, or `default`.
  """
  @spec words(term(), String.t()) :: String.t()
  def words(%{"label" => label}, _default) when is_binary(label) and label != "",
    do: "“" <> label <> "”"

  def words(_place, default), do: default

  # No label, or one already clean (`label/1` would keep it as it is).
  defp label?(nil), do: true
  defp label?(label) when is_binary(label), do: label(label) == label
  defp label?(_label), do: false
end
