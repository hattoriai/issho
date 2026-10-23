defmodule Issho.Work do
  @moduledoc ~S"""
  What an agent is doing in a room, seen by the people in it, and their
  hand on it: a task, its steps and how far it is, and Pause, Resume and
  Stop.

      {:ok, claude} = Issho.Agents.join(MyApp.Issho, agent, "board:42", on_behalf_of: ada)

      :ok = Issho.Work.start(claude, "Plan the release", ["Read the board", "Group the cards", "Write the summary"])
      :ok = Issho.Work.progress(claude, "Read the board", :done)
      :ok = Issho.Work.finish(claude, "Grouped 14 cards in 3 columns.")

  The task is in the agent's state in the room (`"task"`, see
  `Issho.Awareness`), so each page shows it as it goes
  (`Issho.Components.agents/1`), and each start and finish is an event of
  the room (`"agent.started"`, `"agent.finished"`). Agents that reach your
  app over MCP do the same with the `start_task`, `progress` and
  `finish_task` tools.

  ## Pause, Resume, Stop

  The person an agent acts for may pause, resume or stop it in a room,
  and so may anyone your policy allows `:interrupt` (`Issho.Policy`). A
  paused or stopped agent changes nothing more in the room: its next
  transaction is refused (`{:error, {:interrupted, ...}}`), and its next
  tool call, but those that only read, says who paused or stopped it and
  what to do. A transaction is whole: what the agent changed before is
  there, nothing is half done. A paused agent waits for `"agent.resumed"`;
  a stopped one finishes (`finish/2` lets it go on in another task).
  Each is an event of the room: `"agent.interrupted"` (`data`: `%{agent:
  key, action: "pause" | "stop"}`) and `"agent.resumed"`, by the person
  who did it.

  An agent whose work runs under Issho (`Issho.Agents.run/5`) is stopped
  at once: its work ends wherever it is. One that crashes says so
  (`failed/2`).

  ## What is yours

  Issho keeps the task, its state and its events; it decides nothing of
  what a page shows of them. `Issho.Components.agents/1` is a default, to
  use or to leave: the task is in each agent's state in the room
  (`Issho.Awareness`), and its events are the room's (`Issho.Events`), to
  draw your own way.
  """

  alias Issho.{Config, Event, Events, Identity, Participant, Policy, Presence, Session}

  @type step_state :: :pending | :active | :done | :skipped
  @type action :: :pause | :resume | :stop

  @max_steps 20

  @doc """
  Starts a task: its title and its steps (labels; the first is active).
  A task the agent had is replaced. A paused agent starts none until it
  is resumed (`{:error, {:interrupted, ...}}`); a stopped one may.
  """
  @spec start(GenServer.server(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def start(participant, title, steps \\ []) when is_binary(title) and is_list(steps) do
    steps =
      steps
      |> Enum.take(@max_steps)
      |> Enum.with_index()
      |> Enum.map(fn {label, i} ->
        %{"label" => to_string(label), "state" => if(i == 0, do: "active", else: "pending")}
      end)

    task = %{
      "title" => title,
      "steps" => steps,
      "state" => "working",
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    # A stopped agent may begin another task; a paused one waits.
    with :ok <- Participant.clear_interrupt(participant, ["stop"]),
         nil <- Participant.interrupted(participant),
         :ok <- Participant.aware(participant, %{"task" => task}) do
      emit(participant, "agent.started", %{title: title, steps: Enum.map(steps, & &1["label"])})
    else
      %{} = interrupted -> {:error, {:interrupted, interrupted}}
      error -> error
    end
  end

  @doc """
  Says how far the task is: a step (its label or its index) is `:done`
  (the next one pending becomes active), `:active`, `:skipped` or
  `:pending`. Options: `:add`, more steps at the end; `:note`, a few words
  of where it is.
  """
  @spec progress(
          GenServer.server(),
          String.t() | non_neg_integer() | nil,
          step_state(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def progress(participant, step, state \\ :done, opts \\ []) do
    case Participant.awareness(participant) do
      %{"task" => %{} = task} ->
        steps =
          task["steps"]
          |> mark(step, Atom.to_string(state))
          |> Kernel.++(
            for label <- Keyword.get(opts, :add, []),
                do: %{"label" => to_string(label), "state" => "pending"}
          )
          |> Enum.take(@max_steps)
          |> advance()

        task =
          case Keyword.fetch(opts, :note) do
            {:ok, note} -> Map.put(task, "note", note)
            :error -> task
          end

        Participant.aware(participant, %{"task" => %{task | "steps" => steps}})

      _ ->
        {:error, :no_task}
    end
  end

  @doc "Finishes the task, with a few words of what was done; a stop is over with it."
  @spec finish(GenServer.server(), String.t() | nil) :: :ok | {:error, term()}
  def finish(participant, summary \\ nil) do
    title = get_in(Participant.awareness(participant), ["task", "title"])

    with :ok <- Participant.clear_interrupt(participant),
         :ok <- Participant.aware(participant, %{"task" => nil}) do
      if title,
        do: emit(participant, "agent.finished", %{title: title, summary: summary}),
        else: :ok
    end
  end

  @doc """
  Says the agent's work failed: its task, if it has one, is `"failed"`,
  and the room hears `"agent.failed"` (`data`: `%{agent: key, title:
  title, reason: kind}`). The people in the room learn only the kind of
  failure (`"error"`, `"timeout"`, `"killed"` or `"exit"`), not its
  details, which may say more than they should know; your app has them
  in the `[:issho, :agent, :failed]` telemetry event (metadata `:room`,
  `:agent`, `:reason`), to log or to tell in its own words.

  `Issho.Agents.run/5` calls it when the work it runs crashes; call it
  yourself for a work that fails another way.
  """
  @spec failed(GenServer.server(), term()) :: :ok
  def failed(participant, reason) do
    key = Participant.key(participant)
    room = Participant.room(participant)

    :telemetry.execute(
      [:issho, :agent, :failed],
      %{system_time: System.system_time()},
      %{room: room, agent: key, reason: reason}
    )

    title =
      case Participant.awareness(participant) do
        %{"task" => %{} = task} ->
          _ =
            Participant.aware(participant, %{
              "task" => Map.merge(task, %{"state" => "failed", "by" => nil})
            })

          task["title"]

        _ ->
          nil
      end

    emit(participant, "agent.failed", %{agent: key, title: title, reason: kind(reason)})
  end

  # The kind of a failure, in a word for the people.
  defp kind({%{__exception__: true}, _stacktrace}), do: "error"
  defp kind(%{__exception__: true}), do: "error"
  defp kind({:timeout, _}), do: "timeout"
  defp kind(:timeout), do: "timeout"
  defp kind(:killed), do: "killed"
  defp kind(_reason), do: "exit"

  @doc """
  Pauses, resumes or stops the agent `key` in a room, for `by` (an actor
  or an identity), from your server: no policy is asked. From a person's
  page, the agents bar does it through their session, under the policy.
  """
  @spec interrupt(atom(), String.t(), String.t(), action(), keyword()) :: :ok
  def interrupt(instance, room, key, action, opts) when action in [:pause, :resume, :stop] do
    by = Identity.new(Keyword.fetch!(opts, :by))
    broadcast(Config.get(instance).pubsub, room, key, action, by)
  end

  @doc false
  # Whether a session's actor may interrupt the agent `key`: the person it
  # acts for may; anyone else, if the policy allows :interrupt.
  @spec allowed?(Session.t(), String.t()) :: boolean()
  def allowed?(%Session{} = session, key) do
    config = Config.get(session.instance)

    behalf =
      if config.presence do
        with %{"on_behalf_of" => %{"key" => person}} <- Presence.people(session.room)[key],
             do: person
      end

    behalf == session.identity.key or
      Policy.authorize(config.policy, session.identity, session.room, :interrupt) == :ok
  end

  @doc false
  @spec broadcast(atom(), String.t(), String.t(), action(), Identity.t()) :: :ok
  def broadcast(pubsub, room, key, action, %Identity{} = by) do
    Phoenix.PubSub.broadcast(
      pubsub,
      Session.room_topic(room),
      {Issho, :interrupt, room, key, Atom.to_string(action), Identity.public(by)}
    )

    {name, data} =
      case action do
        :resume -> {"agent.resumed", %{agent: key}}
        _ -> {"agent.interrupted", %{agent: key, action: Atom.to_string(action)}}
      end

    Events.broadcast(pubsub, %Event{
      name: name,
      room: room,
      by: by,
      data: data,
      at: DateTime.utc_now()
    })
  end

  @doc false
  # What a model reads when it was interrupted.
  @spec message(map()) :: String.t()
  def message(%{"action" => "pause", "by" => by}),
    do:
      "#{name(by)} paused you. Change nothing more in this room until you are resumed: " <>
        "wait_for_events with names [\"agent.resumed\"], then go on."

  def message(%{"action" => "stop", "by" => by}),
    do:
      "#{name(by)} stopped you. Stop this work in the room: call finish_task with what you " <>
        "did, and tell the person you work for."

  defp name(by), do: by["name"] || by["key"] || "Someone"

  defp emit(participant, name, data) do
    identity = Participant.identity(participant)
    room = Participant.room(participant)
    pubsub = Config.get(Participant.instance(participant)).pubsub

    Events.broadcast(pubsub, %Event{
      name: name,
      room: room,
      by: identity,
      data: data,
      at: DateTime.utc_now()
    })
  end

  defp mark(steps, nil, _state), do: steps

  defp mark(steps, index, state) when is_integer(index),
    do: List.update_at(steps, index, &%{&1 | "state" => state})

  defp mark(steps, label, state) when is_binary(label) do
    case Enum.find_index(steps, &(&1["label"] == label)) do
      nil -> steps ++ [%{"label" => label, "state" => state}]
      index -> mark(steps, index, state)
    end
  end

  # With no step active, the first pending one is.
  defp advance(steps) do
    if Enum.any?(steps, &(&1["state"] == "active")) do
      steps
    else
      case Enum.find_index(steps, &(&1["state"] == "pending")) do
        nil -> steps
        index -> mark(steps, index, "active")
      end
    end
  end
end
