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
  """

  @doc "`:ok` for a place this binding draws, else an error."
  @callback validate(place :: term()) :: :ok | {:error, term()}

  @max_bytes 4_096

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
      module = validator.(doc) -> module.validate(place["at"])
      true -> :ok
    end
  end

  def check(_place, _room, _validator), do: {:error, :invalid_place}
end
