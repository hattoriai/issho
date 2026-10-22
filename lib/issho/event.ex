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
      `%{revision: n}`). Every document emits it.
    * `"person.joined"` and `"person.left"`: someone entered or left the
      room (to come).
    * `"selection.changed"`: someone's place in a document changed (to
      come).
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
end
