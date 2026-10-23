defmodule Issho.Identity do
  @moduledoc """
  An actor as a room knows it: its key, what others see of it, and on
  whose behalf it acts.

  Issho builds one from an `Issho.Actor` when an actor joins (`new/2`),
  signs it into the join token, and gives it to your policy's
  `c:Issho.Policy.authorize/3`. `claims` is a small map of your own that
  travels with it (a tenant's id, a plan), so that a policy can answer
  without reading your database on every message.
  """

  alias Issho.Color

  @kinds [:human, :agent, :service]

  @enforce_keys [:key]
  defstruct [:key, :name, :avatar, :color, :on_behalf_of, kind: :human, claims: %{}]

  @type kind :: :human | :agent | :service

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t() | nil,
          avatar: String.t() | nil,
          color: String.t() | nil,
          kind: kind(),
          on_behalf_of: t() | nil,
          claims: map()
        }

  @doc """
  The identity of an actor. Options: `:on_behalf_of`, another actor (an
  agent acting for a person), and `:claims`.
  """
  @spec new(Issho.Actor.t() | t(), keyword()) :: t()
  def new(actor, opts \\ [])

  def new(%__MODULE__{} = identity, opts) do
    %{identity | on_behalf_of: behalf(opts, identity.on_behalf_of)}
    |> Map.update!(:claims, &Map.merge(&1, Map.new(Keyword.get(opts, :claims, %{}))))
  end

  def new(actor, opts) do
    display = Issho.Actor.display(actor)
    kind = Map.get(display, :kind, :human)

    unless kind in @kinds,
      do:
        raise(
          ArgumentError,
          "an actor's :kind is one of #{inspect(@kinds)}, got: #{inspect(kind)}"
        )

    %__MODULE__{
      key: actor |> Issho.Actor.key() |> to_string(),
      # A name is words people and agents read: one line, nothing hidden.
      name: display |> Map.get(:name) |> text() |> Issho.Text.clean(line: true, max: 80),
      avatar: text(Map.get(display, :avatar)),
      color: Color.sanitize(Map.get(display, :color)),
      kind: kind,
      on_behalf_of: behalf(opts, nil),
      claims: Map.new(Keyword.get(opts, :claims, %{}))
    }
  end

  @doc """
  The identity of a service, known only by its key (`"server"`, `"app"`):
  the author of changes your own code makes with no actor.
  """
  @spec service(String.t()) :: t()
  def service(key) when is_binary(key), do: %__MODULE__{key: key, name: key, kind: :service}

  defp behalf(opts, default) do
    case Keyword.fetch(opts, :on_behalf_of) do
      {:ok, nil} -> nil
      {:ok, actor} -> new(actor)
      :error -> default
    end
  end

  defp text(nil), do: nil
  defp text(value), do: to_string(value)

  @doc """
  The identity as the other people of a room receive it: string keys, no
  claims, and the palette index of an actor with no colour of its own.
  """
  @spec public(t()) :: map()
  def public(%__MODULE__{} = identity) do
    %{
      "key" => identity.key,
      "name" => identity.name,
      "avatar" => identity.avatar,
      "color" => identity.color,
      "palette" => Color.index(identity.key),
      "kind" => Atom.to_string(identity.kind),
      "on_behalf_of" => identity.on_behalf_of && public(identity.on_behalf_of)
    }
  end

  @doc false
  # The identity in a signed token: compact, and read back by from_claims/1.
  @spec to_claims(t()) :: map()
  def to_claims(%__MODULE__{} = identity) do
    identity
    |> public()
    |> Map.drop(["palette"])
    |> Map.put("claims", identity.claims)
    |> Map.update!("on_behalf_of", fn
      nil -> nil
      _ -> to_claims(identity.on_behalf_of)
    end)
  end

  @doc false
  @spec from_claims(map()) :: t()
  def from_claims(%{"key" => key} = claims) do
    %__MODULE__{
      key: key,
      name: claims["name"],
      avatar: claims["avatar"],
      color: Color.sanitize(claims["color"]),
      kind: kind(claims["kind"]),
      on_behalf_of: claims["on_behalf_of"] && from_claims(claims["on_behalf_of"]),
      claims: claims["claims"] || %{}
    }
  end

  defp kind("agent"), do: :agent
  defp kind("service"), do: :service
  defp kind(_), do: :human
end
