defmodule Issho.Action.Invocation do
  @moduledoc """
  A run of an action (`Issho.Action`): its id, the action, its room, who
  (`by`, an `Issho.Identity`, with whom it acts for), its arguments, the
  agent's participant when an agent runs it, how its changes reach the
  room's documents as `by` (`Issho.Action.transact/4`: the person's
  LiveView session, the agent's participant), and whether an agent's
  gestures are shown (`visible`).
  """

  @enforce_keys [:id, :action, :room, :by, :args]
  defstruct [:id, :action, :room, :by, :args, :participant, :transact, visible: true]

  @type t :: %__MODULE__{
          id: String.t(),
          action: module(),
          room: String.t(),
          by: Issho.Identity.t(),
          args: map(),
          participant: pid() | nil,
          transact: (String.t(), term(), keyword() -> {:ok, map()} | {:error, term()}) | nil,
          visible: boolean()
        }
end
