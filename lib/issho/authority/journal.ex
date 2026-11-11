defmodule Issho.Authority.Journal do
  @moduledoc false
  # The accepted transactions that rebuild a document's earlier revisions,
  # kept in its stored map as Issho 0.5.0 keeps them:
  #
  #     "initial" => the engine's state at revision "base"
  #     "base"    => b
  #     "journal" => [event b+1, ..., event revision], oldest first
  #
  # So length(journal) == revision - base, and the journal replayed from
  # "initial", each event with its author, gives the state. 0.5.0 reads
  # "base" as 0 when it is missing and appends to "journal", so it loads
  # and commits to what this keeps. With a cap (the instance's :journal),
  # once the journal is a quarter past it, its oldest events fold into
  # "initial" and "base" moves on: a fold every div(cap, 4) + 1 commits,
  # each applying as many events, so one more apply a commit.

  @type document :: map()

  # A document as the journal keeps it: with its "base". One saved with a
  # journal more than a quarter past the cap starts its
  # journal at the revision it has rather than replaying the one it had.
  # The next transaction saves it.
  @spec load(document(), non_neg_integer() | nil) :: document()
  def load(%{"journal" => journal} = document, cap) when is_list(journal) do
    document = Map.put_new(document, "base", 0)
    if over?(journal, cap), do: restart(document), else: document
  end

  # The document with its journal starting over at the revision it has,
  # from its state.
  @spec restart(document()) :: document()
  def restart(document) do
    Map.merge(document, %{
      "initial" => document["state"],
      "base" => document["revision"],
      "journal" => []
    })
  end

  # The document with an accepted transaction's event after the others.
  @spec append(document(), map()) :: document()
  def append(document, event), do: Map.update!(document, "journal", &(&1 ++ [event]))

  # The document with its oldest events folded into "initial", once the
  # journal is a quarter past the cap, leaving the latest `cap`. `replay`
  # applies events to a state, as the authority does.
  @spec fold(
          document(),
          non_neg_integer() | nil,
          (term(), [map()] -> {:ok, term()} | {:error, term()})
        ) :: {:ok, document()} | {:error, term()}
  def fold(%{"journal" => journal} = document, cap, replay) do
    if over?(journal, cap) do
      {folded, kept} = Enum.split(journal, length(journal) - cap)

      with {:ok, initial} <- replay.(document["initial"], folded) do
        base = document["base"] + length(folded)
        {:ok, %{document | "initial" => initial, "base" => base, "journal" => kept}}
      end
    else
      {:ok, document}
    end
  end

  # What rebuilds a revision of the document's epoch: the state at "base"
  # and the events after it up to that revision.
  @spec rebuild(document(), String.t(), term()) ::
          {:ok, term(), [map()]} | {:error, :unknown_revision}
  def rebuild(
        %{"epoch" => epoch, "base" => base, "revision" => current} = document,
        epoch,
        revision
      )
      when is_integer(revision) and revision >= base and revision <= current,
      do: {:ok, document["initial"], Enum.take(document["journal"], revision - base)}

  def rebuild(_document, _epoch, _revision), do: {:error, :unknown_revision}

  defp over?(journal, cap), do: is_integer(cap) and length(journal) > cap + div(cap, 4)
end
