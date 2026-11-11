defmodule Issho.Authority.Ledger do
  @moduledoc false
  # The receipts of a document's latest accepted transactions, kept in its
  # stored map: which transactions it applied, who made each, and at which
  # revision. Retries and reconnects read them (`check/3`, `accepted/3`),
  # and so does a refused `if_revision` transaction, for what changed
  # since its author looked (`since/3`). The authority is the only caller.
  #
  #     "receipts" => %{id => %{"digest" => d, "revision" => r, "author" => key}}
  #     "horizon"  => h
  #
  # The document has the receipt of every transaction accepted after
  # revision h. A transaction made on revision b was, if it was ever
  # accepted, accepted after b. So when it has no receipt, b >= h means it
  # never was, and it is new; b < h means its receipt may be one that was
  # dropped, so it is refused (:expired) and never applied a second time.

  alias Issho.Transaction

  @type document :: map()

  # A document as the ledger keeps it: with its horizon (0 for one saved
  # before there was one, which kept every receipt), and its receipts
  # trimmed to the latest `keep` (all of them when nil). The next
  # transaction saves it.
  @spec load(document(), pos_integer() | nil) :: document()
  def load(document, keep) do
    document
    |> Map.put_new("horizon", 0)
    |> trim(keep)
  end

  # What the receipts say of a transaction about to be committed. A
  # conditional one made before the horizon goes on, to be refused as
  # stale with what changed since.
  @spec check(document(), Transaction.t(), String.t()) ::
          :new | {:duplicate, non_neg_integer()} | {:error, :id_reused | :expired}
  def check(document, transaction, digest) do
    case document["receipts"][transaction["id"]] do
      %{"digest" => ^digest, "revision" => revision} ->
        {:duplicate, revision}

      %{} ->
        {:error, :id_reused}

      nil ->
        if transaction["base_revision"] < document["horizon"] and
             not Transaction.conditional?(transaction),
           do: {:error, :expired},
           else: :new
    end
  end

  # The document with an accepted transaction's receipt, without those
  # that fell out of the latest `keep`. It trims in steps of a quarter of
  # `keep`, so the walk over the receipts runs once every `keep / 4`
  # commits, not on each.
  @spec record(document(), String.t(), map(), pos_integer() | nil) :: document()
  def record(document, id, receipt, keep) do
    document
    |> put_in(["receipts", id], receipt)
    |> trim(keep)
  end

  # Which of these ids the author has receipts for: a reconnect's pending
  # transactions that were accepted.
  @spec accepted(document(), [String.t()], String.t()) :: [String.t()]
  def accepted(document, ids, author) do
    for id <- List.wrap(ids),
        is_binary(id),
        get_in(document, ["receipts", id, "author"]) == author,
        do: id
  end

  # The latest `limit` changes after revision `seen`, oldest first, each
  # its revision and author: fewer than happened when some fell before the
  # horizon.
  @spec since(document(), non_neg_integer(), pos_integer()) :: [map()]
  def since(document, seen, limit) do
    document["receipts"]
    |> Map.values()
    |> Enum.filter(&(&1["revision"] > seen))
    |> Enum.sort_by(& &1["revision"])
    |> Enum.take(-limit)
    |> Enum.map(&Map.take(&1, ["revision", "author"]))
  end

  defp trim(%{"revision" => revision, "horizon" => horizon} = document, keep)
       when is_integer(keep) and revision - horizon > keep + div(keep, 4) do
    horizon = revision - keep
    receipts = Map.reject(document["receipts"], fn {_id, r} -> r["revision"] <= horizon end)
    %{document | "horizon" => horizon, "receipts" => receipts}
  end

  defp trim(document, _keep), do: document
end
