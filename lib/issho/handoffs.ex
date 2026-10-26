defmodule Issho.Handoffs do
  @moduledoc ~S"""
  An agent hands a task to another agent: a person's assistant to the
  app's bot that tidies a folder, a bot that answers visitors to the
  person's agent that knows the answer.

      {:ok, handoff} =
        Issho.Handoffs.hand_off(MyApp.Issho, "page:7", assistant, "bot:gardener",
          "Tidy the tags of this folder", data: %{"folder" => 3}, on_behalf_of: ada)

  ## The handoff

  It goes to the agent named and to no one else: as an
  `"agent.handed_off"` event to it in the room (`wait_for_events`), and to
  its inbox if it is away, which wakes it (`:on_mention`). Its task,
  place and the app's data are bounded and cleaned (`Issho.Text`), and
  are data for the agent, never instructions to it. It says who handed
  it (`from`) and for whom (`for`): the person the first agent worked
  for, whoever hands it on after.

  The agent it goes to works with its own rights, never the hander's: a
  handoff asks, it grants nothing. The policy says who may hand off to
  whom (`c:Issho.Policy.hand_off/3`); a policy without it lets no one.

  ## The answer

  The agent it went to says what became of it (`reply/5`): `"accepted"`,
  `"declined"` or `"done"`, with a few words. The agent that handed it
  hears it the same way (`"agent.handoff_replied"`). The handoff's id is
  signed, so only the agent it went to can answer it, and only for a
  week.
  """

  alias Issho.{Config, Event, Events, Identity, Place, Policy, Text}

  @salt "issho-handoff-v1"
  @max_age 7 * 24 * 3600
  @max_text 4_000
  @max_data_bytes 4_096
  @statuses ~w(accepted declined done)

  @typedoc "A handoff: its id (signed), who handed what to whom, in which room, for whom."
  @type t :: %{
          id: String.t(),
          room: String.t(),
          from: Identity.t(),
          to: String.t(),
          for: Identity.t() | nil,
          task: String.t(),
          place: map() | nil,
          data: map()
        }

  @doc """
  Hands the task to the agent with the key `to`, in the room, as `by` (an
  actor or identity, an agent's). Options: `:on_behalf_of` (the person
  `by` works for), `:place`, `:data` (a small JSON map). Gives
  `{:ok, handoff}`; its `id` comes back on the answer.
  """
  @spec hand_off(
          atom(),
          String.t(),
          Issho.Actor.t() | Identity.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, t()} | {:error, term()}
  def hand_off(instance, room, by, to, task, opts \\ [])
      when is_binary(room) and is_binary(to) and is_binary(task) do
    config = Config.get(instance)
    from = Identity.new(by, Keyword.take(opts, [:on_behalf_of, :claims]))
    place = Place.clean(opts[:place])

    with :ok <- agent(from),
         true <- to != from.key || {:error, :to_yourself},
         :ok <- Policy.authorize(config.policy, from, room, :read),
         :ok <- Policy.hand_off(config.policy, from, room, to),
         {:ok, task} <- words(task, :empty_task),
         :ok <- Place.check(place, room, fn _doc -> nil end),
         {:ok, data} <- data(Keyword.get(opts, :data, %{})) do
      id = sign(config, %{"r" => room, "f" => from.key, "t" => to, "n" => Issho.Transaction.id()})

      handoff = %{
        id: id,
        room: room,
        from: from,
        to: to,
        for: from.on_behalf_of,
        task: task,
        place: place,
        data: data
      }

      deliver(config, room, from, to, "agent.handed_off", %{
        handoff: id,
        task: task,
        place: place,
        data: data,
        for: from.on_behalf_of && Identity.public(from.on_behalf_of)
      })

      {:ok, handoff}
    end
  end

  @doc """
  Says what became of a handoff, as the agent it went to (`by`):
  `"accepted"`, `"declined"` or `"done"`, with a few words. The agent that
  handed it hears it.
  """
  @spec reply(atom(), String.t(), Issho.Actor.t() | Identity.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def reply(instance, id, by, status, text \\ nil) when is_binary(id) do
    config = Config.get(instance)
    identity = Identity.new(by)

    with {:ok, %{"r" => room, "f" => from, "t" => to}} <- verify(config, id),
         true <- identity.key == to || {:error, :not_yours},
         true <- status in @statuses || {:error, :unknown_status},
         {:ok, text} <- if(text in [nil, ""], do: {:ok, nil}, else: words(text, :empty)) do
      deliver(config, room, identity, from, "agent.handoff_replied", %{
        handoff: id,
        status: status,
        text: text
      })
    end
  end

  @doc "The answers a handoff takes."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  defp agent(%Identity{kind: kind}) when kind in [:agent, :service], do: :ok
  defp agent(_identity), do: {:error, :not_an_agent}

  # To the agent's queue if it is in the room, and to its inbox: it reads
  # it either way, once.
  defp deliver(config, room, by, to, name, data) do
    event = %Event{
      name: name,
      room: room,
      document: data[:place] && data[:place]["doc"],
      by: by,
      to: [to],
      data: data,
      at: DateTime.utc_now()
    }

    :ok = Events.broadcast(config.pubsub, event)
    Issho.Inbox.deliver_to(config, to, event)
  end

  defp sign(config, payload), do: Phoenix.Token.sign(secret(config), @salt, payload)

  defp verify(config, id) do
    case Phoenix.Token.verify(secret(config), @salt, id, max_age: @max_age) do
      {:ok, payload} -> {:ok, payload}
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  defp secret(%Config{secret_key_base: secret}) when is_binary(secret), do: secret
  defp secret(%Config{endpoint: endpoint}), do: endpoint

  defp words(text, empty) do
    case text |> Text.clean(max: @max_text) |> String.trim() do
      "" -> {:error, empty}
      words -> {:ok, words}
    end
  end

  defp data(data) when is_map(data) do
    if byte_size(JSON.encode!(data)) <= @max_data_bytes,
      do: {:ok, Text.for_model(data)},
      else: {:error, :too_large}
  rescue
    _ -> {:error, :invalid_data}
  end

  defp data(_data), do: {:error, :invalid_data}
end
