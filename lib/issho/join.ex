defmodule Issho.Join do
  @moduledoc """
  How a component joins Issho: the same `issho` option in every
  component (Kotoba's editor, Hakushi's canvas, Masu's grid, yours), so an
  app writes it once and it means the same everywhere.

      <.kotoba    issho={[instance: MyApp.Issho, document: "page:1/body"]} user={@user} />
      <.canvas    issho={[instance: MyApp.Issho, document: "page:2"]} user={@user} />
      <.data_grid issho={[instance: MyApp.Issho, document: "page:3/rows"]} user={@user} />

  The keys:

    * `:instance` (required): your Issho instance, `MyApp.Issho`.
    * `:document` (required): the document the component shows. Its room
      is the part before the first `"/"` (`"page:1/body"` is in
      `"page:1"`), so the components of a page whose documents share a
      room share its people, and a pointer goes from one to the other.
    * `:can`: `:write` (the default) or `:read`, what the person may do
      here; your policy is asked as well.
    * `:people`: whether the component shows the room's people itself
      (`true`); `false` on a page that shows Issho's list
      (`Issho.Components.people/1`).
    * `:follow`: whether the component takes part in following (`true`);
      `false`, and it follows no one and shows no one followed, though the
      room's other components do.
    * `:on_behalf_of`: the person an actor acts for (an agent's person).
    * `:claims`: what your policy needs to know of the actor, signed in
      its grant.

  A component takes its own options besides these (Kotoba's `:undo`), and
  says which with `new!/2`'s `extra`; any other key is an error, so a
  typo does not go unnoticed. The person is the component's `user`, as
  `Issho.Actor` says them.
  """

  @enforce_keys [:instance, :document, :room]
  defstruct [
    :instance,
    :document,
    :room,
    :on_behalf_of,
    can: :write,
    people: true,
    follow: true,
    claims: %{},
    extra: %{}
  ]

  @type t :: %__MODULE__{
          instance: atom(),
          document: String.t(),
          room: String.t(),
          can: :write | :read,
          people: boolean(),
          follow: boolean(),
          on_behalf_of: term(),
          claims: map(),
          extra: map()
        }

  @keys [:instance, :document, :can, :people, :follow, :on_behalf_of, :claims]

  @doc """
  The options of a component's `issho`, checked: a keyword list (or a
  map), and `extra`, the keys of the component's own options. Raises
  `ArgumentError` for a missing, unknown or invalid key.
  """
  @spec new!(keyword() | map() | t(), [atom()]) :: t()
  def new!(opts, extra \\ [])

  def new!(%__MODULE__{} = join, _extra), do: join

  def new!(opts, extra) when is_map(opts), do: new!(Map.to_list(opts), extra)

  def new!(opts, extra) when is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "issho takes a keyword list, got: #{inspect(opts)}")

    case Keyword.keys(opts) -- (@keys ++ extra) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "issho takes #{inspect(@keys ++ extra)}, not #{inspect(unknown)}"
    end

    instance = Keyword.get(opts, :instance)
    document = Keyword.get(opts, :document)

    unless is_atom(instance) and not is_nil(instance),
      do: raise(ArgumentError, "issho needs :instance, your Issho instance (MyApp.Issho)")

    unless is_binary(document) and document != "",
      do: raise(ArgumentError, "issho needs :document, the id of the document it shows")

    can = Keyword.get(opts, :can, :write)

    unless can in [:write, :read],
      do: raise(ArgumentError, "issho's :can is :write or :read, got: #{inspect(can)}")

    %__MODULE__{
      instance: instance,
      document: document,
      room: Issho.Policy.room(document),
      can: can,
      people: boolean!(opts, :people),
      follow: boolean!(opts, :follow),
      on_behalf_of: Keyword.get(opts, :on_behalf_of),
      claims: Map.new(Keyword.get(opts, :claims, %{})),
      extra: opts |> Keyword.take(extra) |> Map.new()
    }
  end

  @doc """
  The options of `Issho.Live.grant/4` and `Issho.Live.join/4` for the
  person: `:can`, `:claims` and `:on_behalf_of`.
  """
  @spec grant_opts(t()) :: keyword()
  def grant_opts(%__MODULE__{} = join) do
    [can: join.can, claims: join.claims]
    |> then(&if(join.on_behalf_of, do: [{:on_behalf_of, join.on_behalf_of} | &1], else: &1))
  end

  defp boolean!(opts, key) do
    case Keyword.get(opts, key, true) do
      value when is_boolean(value) -> value
      other -> raise ArgumentError, "issho's #{inspect(key)} is a boolean, got: #{inspect(other)}"
    end
  end
end
