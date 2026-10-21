defmodule Issho.Transaction do
  @moduledoc """
  The envelope of a change to a document, the same for every engine:

      %{
        "id" => "4f1c…",          # unique, chosen by the author; a retry reuses it
        "epoch" => "9a0b…",       # the document's epoch the author saw
        "base_revision" => 41,    # the revision the author saw
        "ops" => [...]            # the engine's operations, opaque to Issho
      }

  The authority gives each accepted transaction the next revision and its
  author, and keeps a receipt of its id: the same transaction sent again
  (after a lost reply, or from an offline queue) is answered with its
  revision and applied once. A different transaction with an id already
  used is refused.
  """

  @max_ops 1_000
  @id ~r/\A[A-Za-z0-9_:.-]{1,160}\z/

  @type t :: %{required(String.t()) => term()}

  @doc "The most operations in one transaction."
  @spec max_ops() :: pos_integer()
  def max_ops, do: @max_ops

  @doc "A new random id, for epochs and transactions."
  @spec id() :: String.t()
  def id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  @doc """
  Checks a transaction's envelope against the document's epoch and
  revision.
  """
  @spec check(term(), String.t(), non_neg_integer()) :: :ok | {:error, atom()}
  def check(
        %{"id" => id, "epoch" => epoch, "base_revision" => base, "ops" => ops},
        current_epoch,
        revision
      ) do
    with :ok <- check_id(id),
         :ok <- if(epoch == current_epoch, do: :ok, else: {:error, :epoch_mismatch}),
         :ok <- check_base(base, revision) do
      check_ops(ops)
    end
  end

  def check(_transaction, _epoch, _revision), do: {:error, :invalid_transaction}

  defp check_id(id) do
    if is_binary(id) and Regex.match?(@id, id), do: :ok, else: {:error, :invalid_id}
  end

  defp check_base(base, revision) do
    if is_integer(base) and base >= 0 and base <= revision,
      do: :ok,
      else: {:error, :invalid_base_revision}
  end

  defp check_ops(ops) when is_list(ops) and ops != [] do
    if length(ops) > @max_ops, do: {:error, :too_many_operations}, else: :ok
  end

  defp check_ops(_ops), do: {:error, :invalid_operations}

  @doc """
  A digest of what a transaction does and who made it, to tell a retry
  from a different transaction that reuses an id.
  """
  @spec digest(t(), String.t()) :: String.t()
  def digest(transaction, author) do
    [author, transaction["epoch"], transaction["base_revision"], transaction["ops"]]
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
