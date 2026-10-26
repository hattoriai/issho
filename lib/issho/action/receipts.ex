defmodule Issho.Action.Receipts do
  @moduledoc false
  # The invocations of an instance's actions on this node, by id: running,
  # or done with their receipt, for `:action_keep` milliseconds. A table
  # anyone writes (claiming an id is one insert_new), swept by its owner.

  use GenServer

  alias Issho.Config

  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(instance),
    do:
      GenServer.start_link(__MODULE__, instance,
        name: Config.child_name(instance, ActionReceipts)
      )

  # An id for a run: new, done before (the same fingerprint), or not ours.
  @spec claim(atom(), String.t(), binary()) ::
          {:ok, :new | {:done, Issho.Action.Receipt.t()}} | {:error, :in_progress | :id_reused}
  def claim(instance, id, fingerprint) do
    table = table(instance)

    if :ets.insert_new(table, {id, fingerprint, :running, now()}) do
      {:ok, :new}
    else
      case :ets.lookup(table, id) do
        [{^id, ^fingerprint, :running, _at}] -> {:error, :in_progress}
        [{^id, ^fingerprint, {:done, receipt}, _at}] -> {:ok, {:done, receipt}}
        [{^id, _other, _state, _at}] -> {:error, :id_reused}
        # Released in between: claim it again.
        [] -> claim(instance, id, fingerprint)
      end
    end
  end

  @spec done(atom(), String.t(), Issho.Action.Receipt.t()) :: true
  def done(instance, id, receipt),
    do: :ets.update_element(table(instance), id, [{3, {:done, receipt}}, {4, now()}])

  # A run that did not happen: the id may run again.
  @spec release(atom(), String.t()) :: non_neg_integer()
  def release(instance, id),
    do: :ets.select_delete(table(instance), [{{id, :_, :running, :_}, [], [true]}])

  @impl true
  def init(instance) do
    :ets.new(table(instance), [:named_table, :public, :set, read_concurrency: true])
    keep = Config.get(instance).action_keep
    schedule(keep)
    {:ok, %{instance: instance, keep: keep}}
  end

  @impl true
  def handle_info(:sweep, %{instance: instance, keep: keep} = state) do
    cutoff = now() - keep

    :ets.select_delete(table(instance), [
      {{:_, :_, {:done, :_}, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule(keep)
    {:noreply, state}
  end

  defp schedule(keep), do: Process.send_after(self(), :sweep, max(div(keep, 4), 1_000))

  defp table(instance), do: Config.child_name(instance, ActionReceipts)
  defp now, do: System.monotonic_time(:millisecond)
end
