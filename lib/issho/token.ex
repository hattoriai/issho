defmodule Issho.Token do
  @moduledoc """
  Short-lived, signed credentials to join one room as one actor.

  Your LiveView signs a token after it has authenticated the person and
  checked they may join; the browser joins the room's channel with it.
  The token holds the actor's identity (`Issho.Identity`, with your
  `claims`) and what it may do: `:read` or `:write`. A read token never
  writes, whatever the browser sends.

      token = Issho.Token.sign(MyApp.Issho, current_user, "board:42", can: :write)

  Tokens are good for joining for the instance's `:token_max_age` (300
  seconds). The browser renews them through the LiveView before then; a
  session already joined stays until it leaves, its access is revoked
  (`Issho.revoke/3`), or the policy refuses it.
  """

  alias Issho.{Config, Identity}

  @salt "issho-join-v1"

  @doc """
  Signs a token for the actor to join the room. Options: `:can` (`:write`
  or `:read`, `:write` unless given), `:claims` (a small map of your own
  for the policy) and `:on_behalf_of` (the actor an agent acts for).
  """
  @spec sign(atom(), Issho.Actor.t() | Identity.t(), String.t(), keyword()) :: String.t()
  def sign(instance, actor, room, opts \\ []) when is_binary(room) do
    can = Keyword.get(opts, :can, :write)

    unless can in [:read, :write],
      do: raise(ArgumentError, "a token's :can is :read or :write, got: #{inspect(can)}")

    identity = Identity.new(actor, Keyword.take(opts, [:claims, :on_behalf_of]))

    Phoenix.Token.sign(secret(Config.get(instance)), @salt, %{
      "room" => room,
      "can" => Atom.to_string(can),
      "who" => Identity.to_claims(identity)
    })
  end

  @doc """
  Verifies a token for the room. Gives `{:ok, identity, can}`, or
  `{:error, :expired | :invalid | :other_room}`.
  """
  @spec verify(atom(), String.t(), String.t()) ::
          {:ok, Identity.t(), :read | :write} | {:error, :expired | :invalid | :other_room}
  def verify(instance, token, room) when is_binary(token) do
    config = Config.get(instance)

    case Phoenix.Token.verify(secret(config), @salt, token, max_age: config.token_max_age) do
      {:ok, %{"room" => ^room, "can" => can, "who" => who}} ->
        {:ok, Identity.from_claims(who), if(can == "write", do: :write, else: :read)}

      {:ok, _other} ->
        {:error, :other_room}

      {:error, :expired} ->
        {:error, :expired}

      {:error, _reason} ->
        {:error, :invalid}
    end
  end

  def verify(_instance, _token, _room), do: {:error, :invalid}

  defp secret(%Config{secret_key_base: secret}) when is_binary(secret), do: secret
  defp secret(%Config{endpoint: endpoint}), do: endpoint
end
