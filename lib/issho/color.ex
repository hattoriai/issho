defmodule Issho.Color do
  @moduledoc """
  The colours of the people of a room.

  An actor's own colour goes to other people's browsers, so only a plain
  CSS colour passes (`sanitize/1`). An actor with no colour gets an index
  into the theme's palette (`index/1`, 1 to 8, the same for a key in every
  browser and node): the theme decides the colours, so Sumi and a dark mode
  can choose their own (`--issho-person-1` … `--issho-person-8`).
  """

  @palette_size 8
  @pattern ~r/^(#[0-9a-fA-F]{3,8}|[a-z]{3,20}|(rgb|rgba|hsl|hsla|oklch|oklab)\([0-9a-z.,%\s\/+-]{1,64}\))$/

  @doc "The number of colours in a theme's palette."
  @spec palette_size() :: pos_integer()
  def palette_size, do: @palette_size

  @doc """
  The colour if it is a plain CSS colour, else `nil`.

      iex> Issho.Color.sanitize("#2563eb")
      "#2563eb"
      iex> Issho.Color.sanitize("red; background: url(x)")
      nil
  """
  @spec sanitize(term()) :: String.t() | nil
  def sanitize(color) when is_binary(color) do
    if byte_size(color) <= 80 and Regex.match?(@pattern, color), do: color
  end

  def sanitize(_color), do: nil

  @doc """
  The palette index of a key, from 1 to 8.

      iex> Issho.Color.index("user:4") in 1..8
      true
  """
  @spec index(String.t()) :: pos_integer()
  def index(key) when is_binary(key), do: :erlang.phash2(key, @palette_size) + 1
end
