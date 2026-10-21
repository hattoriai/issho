defmodule Issho.Motion do
  @moduledoc """
  How an agent moves on the page, so that the people can follow it: it
  goes to where it works, presses, drags and lets go, and clicks, as a
  hand would. Only where it goes is sent, once for each gesture; each
  browser draws the way there on its own page, and the agent waits as long
  as that takes before its change lands.

  A gesture's target is a place of a document, in the document's own terms
  (`%{"doc" => "notebook:7/body", "at" => at}`: a caret, a node, a cell),
  or an element of the app's page that it named (`%{"anchor" => "edit"}`,
  the element with `data-issho-anchor="edit"`). Components' tools move
  their agents with it; an app's own tools too:

      # An app's tool: the agent goes to the button, clicks it, then acts.
      :ok = Issho.Motion.click(participant, %{"anchor" => "new-page"})
      {:ok, page} = Pages.create(...)

  ## When it moves

  An agent moves only for someone who can see it. Each browser of the
  room says what it shows (the page in the foreground, the documents of
  its components on the screen, whether its person wants motion): when no
  person of the room shows the target, or none wants motion, the agent is
  there at once. A browser that says nothing, or a person who follows the
  agent, counts as watching: the agent rather moves for no one than skips
  someone who looks.

  ## Time

  A gesture takes `flight` milliseconds to another document or element,
  `step` within the same one (each browser fits its own way into it).
  A tool call has a `budget`: its gestures together never take longer, the
  later ones shorter, then at once.

      config :issho, Issho.Motion,
        travel: true,     # false: agents are there at once, everywhere
        flight: 450,
        step: 300,
        click: 150,       # the moment on a click before what it does
        budget: 3_000     # the most a tool call's gestures take, together

  A component may move its agents or not (Kotoba's, Masu's and Hakushi's
  `travel`); this one setting turns motion off for all of them.
  """

  alias Issho.Participant

  @gestures ~w(move press drag release click)

  @typedoc "Where a gesture goes: a place of a document, or an element of the page."
  @type target :: %{required(String.t()) => term()}

  @typedoc "A gesture: `:move` to go there, `:press` and `:release` around a `:drag`, `:click`."
  @type gesture :: :move | :press | :drag | :release | :click

  @doc """
  Goes to a target. Options: `:gesture` (`:move`), `:place` (whether a
  document's target is also the agent's place, its selection there:
  true), `:travel` (a component's own setting: true), and `:aware`, more
  of the agent's awareness state that changes with the gesture, in the
  same message (a canvas's cursor and selection).
  """
  @spec go(GenServer.server(), target(), keyword()) :: :ok | {:error, term()}
  def go(participant, target, opts \\ []) do
    gesture = opts |> Keyword.get(:gesture, :move) |> to_string()
    true = gesture in @gestures

    aware = Participant.awareness(participant)
    before = get_in(aware, ["motion", "to"])
    seq = (get_in(aware, ["motion", "seq"]) || 0) + 1

    ms =
      if Keyword.get(opts, :travel, true) and travel?() and watched?(participant, target),
        do: fit(duration(before, target)),
        else: 0

    changes = %{"motion" => %{"to" => target, "gesture" => gesture, "ms" => ms, "seq" => seq}}

    changes =
      if Map.has_key?(target, "doc") and Keyword.get(opts, :place, true),
        do: Map.put(changes, "place", Map.take(target, ["doc", "at"])),
        else: changes

    changes = Map.merge(Keyword.get(opts, :aware, %{}), changes)

    with :ok <- Participant.aware(participant, changes) do
      wait(if gesture == "click" and ms > 0, do: ms + setting(:click, 150), else: ms)
    end
  end

  @doc "Goes to a target and clicks it: the people see it ring."
  @spec click(GenServer.server(), target(), keyword()) :: :ok | {:error, term()}
  def click(participant, target, opts \\ []),
    do: go(participant, target, Keyword.put(opts, :gesture, :click))

  @doc """
  Selects as a drag does: pressed at `from`, let go at `to` (a range of
  the same document), in two gestures.
  """
  @spec drag(GenServer.server(), target(), target(), keyword()) :: :ok | {:error, term()}
  def drag(participant, from, to, opts \\ []) do
    with :ok <- go(participant, from, Keyword.put(opts, :gesture, :press)),
         do: go(participant, to, Keyword.put(opts, :gesture, :release))
  end

  @doc """
  A moment on a target, before what the agent does there, so that the
  people see what will change: taken only when someone sees it, within
  the tool call's budget. Options: `:travel`.
  """
  @spec pause(GenServer.server(), target(), non_neg_integer(), keyword()) :: :ok
  def pause(participant, target, ms, opts \\ []) do
    if Keyword.get(opts, :travel, true) and travel?() and watched?(participant, target),
      do: wait(fit(ms)),
      else: :ok
  end

  @doc """
  Whether anyone of the room may see the agent go to a target, and wants
  to: a person whose browser shows it (its page in the foreground, and
  for a document's target, the document's component on the screen),
  whose browser says nothing of what it shows, or who follows the agent.
  """
  @spec watched?(GenServer.server(), target()) :: boolean()
  def watched?(participant, target) do
    self_key = Participant.key(participant)
    people = Participant.people(participant)

    # A room whose presence does not know this agent (none, or not yet): it
    # cannot tell who sees it, so someone may.
    not match?(%{^self_key => %{"person" => %{"kind" => _}}}, people) or
      people
      |> Enum.reject(fn {key, %{"person" => person}} ->
        key == self_key or person["kind"] in ["agent", :agent]
      end)
      |> Enum.any?(fn
        # Someone here who says nothing yet: they may see it.
        {_key, %{"states" => []}} -> true
        {_key, %{"states" => states}} -> Enum.any?(states, &sees?(&1, target, participant))
      end)
  end

  defp sees?(%{"view" => %{} = view}, target, participant) do
    cond do
      view["motion"] == "reduced" -> false
      view["page"] == false -> false
      follows?(view, participant) -> true
      Map.has_key?(target, "doc") and is_list(view["docs"]) -> target["doc"] in view["docs"]
      true -> true
    end
  end

  # A browser that says nothing of what it shows: it may show it.
  defp sees?(_state, _target, _participant), do: true

  defp follows?(%{"follow" => key}, participant) when is_binary(key),
    do: key == Participant.key(participant)

  defp follows?(_view, _participant), do: false

  @doc false
  # A gesture's duration: farther, to another document or element; nearer,
  # within the one it is in.
  @spec duration(target() | nil, target()) :: non_neg_integer()
  def duration(before, target) do
    if same?(before, target), do: setting(:step, 300), else: setting(:flight, 450)
  end

  defp same?(%{"doc" => doc}, %{"doc" => doc}), do: true
  defp same?(%{"anchor" => anchor}, %{"anchor" => anchor}), do: true
  defp same?(_before, _target), do: false

  @doc """
  Runs a function with the time budget of a tool call: the gestures it
  makes together never take longer. `Issho.Tools` runs each tool so.
  """
  @spec within(non_neg_integer() | nil, (-> result)) :: result when result: term()
  def within(ms \\ nil, fun) do
    previous = Process.get(__MODULE__)
    Process.put(__MODULE__, now() + (ms || setting(:budget, 3_000)))

    try do
      fun.()
    after
      if previous, do: Process.put(__MODULE__, previous), else: Process.delete(__MODULE__)
    end
  end

  # What is left of the budget, for a gesture: all of it, a part, or none.
  defp fit(ms) do
    case Process.get(__MODULE__) do
      nil ->
        ms

      deadline ->
        left = deadline - now()
        if left < 60, do: 0, else: min(ms, left)
    end
  end

  defp wait(0), do: :ok

  defp wait(ms) do
    Process.sleep(ms)
    :ok
  end

  @doc "Whether agents move at all (`config :issho, Issho.Motion, travel: false` turns it off)."
  @spec travel?() :: boolean()
  def travel?, do: setting(:travel, true)

  defp setting(key, default),
    do: Keyword.get(Application.get_env(:issho, __MODULE__, []), key, default)

  defp now, do: System.monotonic_time(:millisecond)
end
