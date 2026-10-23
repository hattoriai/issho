defmodule Issho.Text do
  @moduledoc ~S"""
  What people write, made safe to keep, to show and to give a model:
  their words, without what no one sees.

  Text in a room comes from people's browsers, apps and agents: comments,
  names, statuses, an agent's task. Some of what a string can hold is
  invisible on the page and still read by a model, or turns what is shown
  around: control characters, bidirectional overrides, zero-width
  characters, Unicode's tag characters (U+E0000–U+E007F, which spell
  text no one sees), the variation selectors beyond the sixteen emoji use,
  and private-use characters. `clean/2` takes them out and keeps the
  words: letters of every script, emoji (with their joiners and their
  variation selectors), line breaks where they belong.

      iex> Issho.Text.clean("Ship it\u202Eon Friday")
      "Ship iton Friday"
      iex> Issho.Text.clean("Ada\nLovelace", line: true)
      "Ada Lovelace"
      iex> Issho.Text.clean("A long title", max: 6)
      "A lon…"

  Issho cleans what it keeps (a comment's body, a name, a status, a task)
  and what its tools give a model (`for_model/1`), so a page cannot slip a
  model instructions no person sees. Clean is not trusted: what people
  wrote is still theirs, for an agent to weigh, never instructions to it.
  """

  # Controls (but tab and line feed), format characters (but the zero-width
  # joiner of emoji), private use, lone surrogates; the variation selectors
  # past the sixteen of emoji. \p{Cf} holds the bidirectional controls, the
  # zero-width ones and the tag characters.
  @hidden ~r/(?![\t\n\x{200D}])[\p{Cc}\p{Cf}\p{Co}]|[\x{E0100}-\x{E01EF}]/u
  @joiners ~r/\x{200D}{2,}/u
  @spaces ~r/[ \t]*\n[ \t]*|[\t\n ]+/u

  @doc """
  The text without what no one sees, or `nil` for `nil`. Options:
  `:line` (`true`: one line, its breaks and runs of spaces as one space),
  `:max` (at most this many characters, the last of them "…").
  """
  @spec clean(String.t() | nil, keyword()) :: String.t() | nil
  def clean(text, opts \\ [])
  def clean(nil, _opts), do: nil

  def clean(text, opts) when is_binary(text) do
    text
    |> String.replace_invalid()
    |> String.replace("\r\n", "\n")
    |> String.replace(@hidden, "")
    |> String.replace(@joiners, "\u200D")
    |> line(opts[:line])
    |> cut(opts[:max])
  end

  @doc "Whether the text is already clean (`clean/1` would not change it)."
  @spec clean?(String.t()) :: boolean()
  def clean?(text) when is_binary(text), do: String.valid?(text) and clean(text) == text

  @doc """
  A tool's result for a model: every string in it cleaned (`clean/1`),
  through maps and lists, keys too. For what people wrote and an agent
  reads (comments, names, statuses, events), not for a document whose
  offsets an agent edits by.
  """
  @spec for_model(term()) :: term()
  def for_model(value) when is_binary(value), do: clean(value)
  def for_model(value) when is_list(value), do: Enum.map(value, &for_model/1)

  def for_model(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, item} -> {for_model(key), for_model(item)} end)

  def for_model(value), do: value

  defp line(text, true), do: text |> String.replace(@spaces, " ") |> String.trim()
  defp line(text, _many), do: text

  defp cut(text, nil), do: text

  defp cut(text, max) when is_integer(max) and max > 0 do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
