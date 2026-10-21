defmodule Issho.Presence do
  @moduledoc """
  Who is in a room: `Phoenix.Presence`, as it is, on your app's PubSub.

  Issho starts it for you (the instance's `:presence` option, `true`
  unless given) and tracks each session under its actor's key, so an actor
  in two tabs is one entry with two metas. Each meta is the actor's public
  identity (`Issho.Identity.public/1`) and when it joined.

  Presence is for who is here, which changes when people come and go.
  Where they are changes many times a second and goes through awareness
  (`Issho.Awareness`), which is not replicated by Presence's CRDT.

  An app with several Issho instances on one node gives each a
  `presence: false` but the first, and they share this one.
  """

  use Phoenix.Presence, otp_app: :issho

  @doc false
  @spec topic(String.t()) :: String.t()
  def topic(room), do: "issho:presence:" <> room

  @doc "The actors in a room: their keys and public identities."
  @spec people(String.t()) :: %{String.t() => map()}
  def people(room) do
    for {key, %{metas: [meta | _]}} <- list(topic(room)), into: %{}, do: {key, meta}
  end
end
