defmodule Issho.Action.Receipt do
  @moduledoc """
  What an action did: its invocation's id, the action's name, the room,
  who, the result of its change, and when. `replayed` is `true` for a
  retry that found it done, and did nothing again.
  """

  @enforce_keys [:id, :action, :room, :by, :at]
  defstruct [:id, :action, :room, :by, :result, :at, replayed: false]

  @type t :: %__MODULE__{
          id: String.t(),
          action: String.t(),
          room: String.t(),
          by: Issho.Identity.t(),
          result: term(),
          at: DateTime.t(),
          replayed: boolean()
        }
end
