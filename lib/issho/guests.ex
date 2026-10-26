defmodule Issho.Guests do
  @moduledoc ~S"""
  Visitors no one knows: someone reading a public page, signed in nowhere,
  who may say something there (a comment, a question to the page's bot).

      # In the LiveView of a public page: one visitor, kept in its session.
      guest = Issho.Guests.new(session["guest"])
      grant = Issho.Live.grant(MyApp.Issho, guest, "page:7", can: :read)

  A guest is an actor of `kind: :guest`, with a key of its own
  (`"guest:…"`) that the app keeps for the browser's session, so that the
  page's people see one visitor, however often it comes back. Its name is
  "Visitor" unless the app gives one.

  What a guest may do is your policy's, as for anyone (`c:Issho.Policy.authorize/3`
  sees `kind: :guest`), with two limits Issho keeps whatever the policy
  says:

    * a guest never writes, locks or interrupts: it reads, comments and
      asks, where the policy lets it;
    * its comments and requests are limited to the instance's
      `:guest_limit`, `{count, seconds}` (10 a minute unless given): one
      more is refused, `{:error, :too_many}`, until the minute is over.
  """
  use GenServer

  alias Issho.Config

  @doc """
  A guest: the actor of a visitor, from the key the app kept for its
  session (or a new one when nil), and a name (`"Visitor"` unless given).
  """
  @spec new(String.t() | nil, String.t()) :: Issho.Actor.t()
  def new(key \\ nil, name \\ "Visitor")

  def new("guest:" <> _ = key, name), do: %{id: key, name: name, kind: :guest}

  def new(_key, name),
    do: %{
      id: "guest:" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      name: name,
      kind: :guest
    }

  @doc false
  # What a guest never does, whatever the policy says.
  @spec forbidden?(atom()) :: boolean()
  def forbidden?(action), do: action in [:write, :lock, :interrupt]

  @doc false
  # One more comment or request of a guest: `:ok`, or `{:error, :too_many}`
  # past the instance's limit in its window.
  @spec hit(atom(), String.t()) :: :ok | {:error, :too_many}
  def hit(instance, key) do
    {count, seconds} = Config.get(instance).guest_limit
    window = div(System.system_time(:second), seconds)
    table = table(instance)

    case :ets.update_counter(table, {key, window}, 1, {{key, window}, 0}) do
      n when n <= count -> :ok
      _over -> {:error, :too_many}
    end
  end

  defp table(instance), do: Config.child_name(instance, Guests)

  @doc false
  def start_link(instance), do: GenServer.start_link(__MODULE__, instance, name: table(instance))

  @impl true
  def init(instance) do
    :ets.new(table(instance), [:named_table, :public, :set, write_concurrency: true])
    {:ok, instance, {:continue, :sweep}}
  end

  # The windows gone by, swept now and then.
  @impl true
  def handle_continue(:sweep, instance), do: {:noreply, sweep(instance)}

  @impl true
  def handle_info(:sweep, instance), do: {:noreply, sweep(instance)}

  defp sweep(instance) do
    {_count, seconds} = Config.get(instance).guest_limit
    window = div(System.system_time(:second), seconds)
    :ets.select_delete(table(instance), [{{{:_, :"$1"}, :_}, [{:<, :"$1", window}], [true]}])
    Process.send_after(self(), :sweep, seconds * 1_000)
    instance
  end
end
