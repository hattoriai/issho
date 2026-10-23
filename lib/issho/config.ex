defmodule Issho.Config do
  @moduledoc false
  # The options of an Issho instance, checked when it starts and kept in
  # :persistent_term under its name, so that every process of the instance
  # reads them without a call.

  @enforce_keys [:name, :pubsub, :policy]
  defstruct [
    :name,
    :pubsub,
    :policy,
    :store,
    :secret_key_base,
    :endpoint,
    :on_mention,
    registry: :global,
    presence: true,
    ttl: 30_000,
    awareness_interval: 50,
    awareness_full_every: 100,
    max_document_bytes: 16_000_000,
    max_message_bytes: 1_000_000,
    awareness_max_bytes: 65_536,
    token_max_age: 300,
    stream_max_bytes: 1_000_000,
    room_max_streams: 32,
    stream_keep: 300_000
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts) do
    known = Map.keys(%__MODULE__{name: nil, pubsub: nil, policy: nil}) -- [:__struct__]

    case Keyword.keys(opts) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown Issho options: #{inspect(unknown)}"
    end

    for key <- [:name, :pubsub, :policy], !opts[key] do
      raise ArgumentError, "Issho needs the #{inspect(key)} option"
    end

    case opts[:store] do
      nil -> :ok
      {module, _context} when is_atom(module) -> :ok
      other -> raise ArgumentError, "Issho's :store is {module, context}, got: #{inspect(other)}"
    end

    unless opts[:secret_key_base] || opts[:endpoint],
      do: raise(ArgumentError, "Issho needs :endpoint or :secret_key_base, to sign join tokens")

    check_on_mention!(opts[:on_mention])
    struct!(__MODULE__, opts)
  end

  defp check_on_mention!(nil), do: :ok
  defp check_on_mention!({module, function}) when is_atom(module) and is_atom(function), do: :ok
  defp check_on_mention!(function) when is_function(function, 2), do: :ok

  defp check_on_mention!(other),
    do: raise(ArgumentError, "Issho's :on_mention is {module, function}, got: #{inspect(other)}")

  @spec put(t()) :: :ok
  def put(%__MODULE__{name: name} = config), do: :persistent_term.put({Issho, name}, config)

  @spec get(atom()) :: t()
  def get(name) do
    :persistent_term.get({Issho, name}, nil) ||
      raise ArgumentError, "no Issho instance named #{inspect(name)} is running"
  end

  @spec delete(atom()) :: :ok
  def delete(name) do
    :persistent_term.erase({Issho, name})
    :ok
  end

  # The names of an instance's processes.
  @spec child_name(atom(), atom()) :: atom()
  def child_name(name, part), do: Module.concat(name, part)
end
