defmodule Issho.Action.Invocation do
  @moduledoc """
  A run of an action (`Issho.Action`): its id, the action, its room, who
  (`by`, an `Issho.Identity`, with whom it acts for), its arguments, and
  the agent's participant when an agent runs it.
  """

  @enforce_keys [:id, :action, :room, :by, :args]
  defstruct [:id, :action, :room, :by, :args, :participant]

  @type t :: %__MODULE__{
          id: String.t(),
          action: module(),
          room: String.t(),
          by: Issho.Identity.t(),
          args: map(),
          participant: pid() | nil
        }
end
