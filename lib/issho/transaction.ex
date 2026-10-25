defmodule Issho.Transaction do
  @moduledoc """
  The envelope of a change to a document, the same for every engine:

      %{
        "id" => "4f1c…",          # unique, chosen by the author; a retry reuses it
        "epoch" => "9a0b…",       # the document's epoch the author saw
        "base_revision" => 41,    # the revision the author saw
        "ops" => [...],           # the engine's operations, opaque to Issho
        "if_revision" => 41       # optional: only on this revision
      }

  The authority gives each accepted transaction the next revision and its
  author, and keeps a receipt of its id: the same transaction sent again
  (after a lost reply, or from an offline queue) is answered with its
  revision and applied once. A different transaction with an id already
  used is refused.

  ## Only on what the author saw

  Without `"if_revision"`, a transaction on an older revision applies to
  the latest, as its engine merges concurrent changes. With it (the
  `"base_revision"` again), it applies only if the document is still at
  that revision of that epoch: when anyone changed it since, or it began
  a new epoch, the whole transaction is refused, before its operations or
  the document's hook run, with `{:error, {:stale, details}}`: the
  document's version now, and the changes since (their revisions and
  authors, the latest 20) when the journal still holds them. An agent
  that read the document, then thought, changes what it read, or reads
  it again (`Issho.Version`).

  The condition is part of what the transaction is: a retry of an
  accepted one gets its receipt even though the document went on; its id
  with another condition is refused like any other reuse.
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

  @doc false
  # A transaction of operations for a document's authority: on its latest
  # revision, or, `:if_revision` (an `Issho.Version` token), only on that
  # one. Its id is `:id`'s, else a new one.
  @spec new(GenServer.server(), [term()], keyword()) :: {:ok, t()} | {:error, term()}
  def new(authority, ops, opts \\ []) do
    envelope = %{"id" => Keyword.get_lazy(opts, :id, &id/0), "ops" => ops}

    case Keyword.get(opts, :if_revision) do
      nil ->
        with {:ok, snapshot} <- Issho.Authority.snapshot(authority),
             do: {:ok, Map.merge(envelope, base(snapshot["epoch"], snapshot["revision"]))}

      token ->
        # What it saw, as it says it: no read now, the authority checks.
        with {:ok, {epoch, revision}} <- Issho.Version.parse(token),
             do:
               {:ok,
                envelope
                |> Map.merge(base(epoch, revision))
                |> Map.put("if_revision", revision)}
    end
  end

  defp base(epoch, revision), do: %{"epoch" => epoch, "base_revision" => revision}

  @doc """
  Checks a transaction's envelope against the document's epoch and
  revision.
  """
  @spec check(term(), String.t(), non_neg_integer()) :: :ok | {:error, atom()}
  def check(
        %{"id" => id, "epoch" => epoch, "base_revision" => base, "ops" => ops} = transaction,
        current_epoch,
        revision
      ) do
    with :ok <- check_id(id),
         :ok <- if(epoch == current_epoch, do: :ok, else: {:error, :epoch_mismatch}),
         :ok <- check_base(base, revision),
         :ok <- check_condition(transaction, base) do
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

  # The revision it is made on, if given, is the one it saw.
  defp check_condition(%{"if_revision" => nil}, _base), do: :ok
  defp check_condition(%{"if_revision" => base}, base), do: :ok
  defp check_condition(%{"if_revision" => _other}, _base), do: {:error, :invalid_if_revision}
  defp check_condition(_transaction, _base), do: :ok

  @doc "Whether it applies only on the revision it saw (`\"if_revision\"`)."
  @spec conditional?(t()) :: boolean()
  def conditional?(transaction), do: is_integer(transaction["if_revision"])

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
    # A condition is part of it; an unconditional one's digest is as it was.
    [author, transaction["epoch"], transaction["base_revision"], transaction["ops"]]
    |> then(&if(conditional?(transaction), do: &1 ++ [transaction["if_revision"]], else: &1))
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
