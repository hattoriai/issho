defmodule Issho.Event do
  @moduledoc """
  Something that happened in a room, for whoever acts on it: the app's
  code, the room's components, agents (`Issho.Events`).

    * `:name`: what happened, a dotted name (`"document.changed"`).
    * `:room`: the room it happened in.
    * `:document`: the document it is about, or `nil`.
    * `:by`: who made it happen (`Issho.Identity`: a person, an agent and
      whom it acts for, a service), or `nil`.
    * `:data`: what else there is to know, a map of the event's.
    * `:at`: when, a `DateTime` in UTC.

  ## Names

  Issho's own names, and those its components emit, are reserved, so that
  every app and component means the same by them:

    * `"document.changed"`: a document accepted a change (`data`:
      `%{revision: n}`). Every document emits it, and so does a component
      whose content is its own, not an Issho document's (Masu's rows:
      `data: %{op: :update, count: n}`).
    * `"person.joined"` and `"person.left"`: someone entered the room
      (their first tab, or an agent) or left it (their last), `data`:
      `%{can: "write"}`.
    * `"selection.changed"`: a session's place changed (`data`: `%{place:
      place, session: id}`, the place `nil` when it has none): what
      someone selected, in the document's own terms.
    * `"agent.started"` and `"agent.finished"`: an agent began or ended
      a piece of work (to come).
    * `"thread.created"`, `"comment.created"`: comments (to come).

  An app's own events take a name of its own, outside these
  (`"retro.voted"`, `"myapp.toast"`).
  """

  @enforce_keys [:name, :room, :at]
  defstruct [:name, :room, :document, :by, :at, data: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          room: String.t(),
          document: String.t() | nil,
          by: Issho.Identity.t() | nil,
          data: map(),
          at: DateTime.t()
        }

  @doc """
  The event as JSON (string keys, the time in ISO 8601), for a model or a
  browser: who made it happen is their public identity, and the data's
  values that JSON has no way to say (a struct, a tuple) are inspected.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      "name" => event.name,
      "room" => event.room,
      "document" => event.document,
      "by" => event.by && by(event.by),
      "data" => json(event.data),
      "at" => DateTime.to_iso8601(event.at)
    }
  end

  defp by(identity) do
    identity
    |> Issho.Identity.public()
    |> Map.take(["key", "name", "kind", "on_behalf_of"])
    |> Map.update!("on_behalf_of", &(&1 && Map.take(&1, ["key", "name", "kind"])))
  end

  defp json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json(%Date{} = value), do: Date.to_iso8601(value)
  defp json(%_{} = value), do: inspect(value)
  defp json(value) when is_map(value), do: Map.new(value, fn {k, v} -> {key(k), json(v)} end)
  defp json(value) when is_list(value), do: Enum.map(value, &json/1)
  defp json(value) when is_boolean(value) or is_nil(value), do: value
  defp json(value) when is_atom(value), do: Atom.to_string(value)
  defp json(value) when is_binary(value) or is_number(value), do: value
  defp json(value), do: inspect(value)

  defp key(key) when is_binary(key), do: key
  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: inspect(key)
end
