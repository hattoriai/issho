defmodule Issho.Version do
  @moduledoc """
  What someone saw of a document, as one token: its epoch and revision,
  `"9a0b…:41"`. `read_document` and a component's reads give it; a change
  made `if_revision` it applies only to that version, or is refused as
  stale (`Issho.Transaction`).

  The epoch is part of it: a document reset or upgraded starts a new
  epoch, its revisions counted again from where it began, and a revision
  of the last epoch says nothing of the new one.
  """

  @doc "The token of an epoch and a revision."
  @spec new(String.t(), non_neg_integer()) :: String.t()
  def new(epoch, revision) when is_binary(epoch) and is_integer(revision),
    do: epoch <> ":" <> Integer.to_string(revision)

  @doc ~S(The version of a snapshot: its "epoch" and "revision".)
  @spec of(map()) :: String.t()
  def of(%{"epoch" => epoch, "revision" => revision}), do: new(epoch, revision)

  @doc """
  A token's epoch and revision.

      iex> Issho.Version.parse("9a0b:41")
      {:ok, {"9a0b", 41}}
      iex> Issho.Version.parse("41")
      {:error, :invalid_version}
  """
  @spec parse(term()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, :invalid_version}
  def parse(token) when is_binary(token) do
    with [epoch, revision] <- String.split(token, ":"),
         true <- epoch != "",
         {revision, ""} when revision >= 0 <- Integer.parse(revision) do
      {:ok, {epoch, revision}}
    else
      _ -> {:error, :invalid_version}
    end
  end

  def parse(_token), do: {:error, :invalid_version}
end
