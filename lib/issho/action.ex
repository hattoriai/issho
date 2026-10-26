defmodule Issho.Action do
  @moduledoc ~S"""
  One thing your app does, for whoever does it: a person's button, a
  keyboard command, your Elixir code, an agent's tool. Each runs the same
  action, on the server, under the same policy, and is told the same
  outcome; an agent does not get a tool of its own that does it its own
  way.

      defmodule MyApp.Actions.CheckItem do
        use Issho.Action,
          name: "check_item",
          description: "Checks or unchecks an item of a checklist.",
          can: :write

        arg :list, :string, required: true
        arg :item, :string, required: true
        arg :done, :boolean, required: true

        @impl Issho.Action
        def target(%{list: list}), do: "checklist:#{list}"

        @impl Issho.Action
        def run(%{item: item, done: done}, invocation) do
          MyApp.Checklists.check(item, done, by: invocation.by)
        end
      end

  A person, from a LiveView in the room (`Issho.Live.act/3`):

      def handle_event("check", %{"item" => item, "done" => done}, socket) do
        args = %{list: socket.assigns.list.id, item: item, done: done == "true"}

        case Issho.Live.act(MyApp.Actions.CheckItem, args) do
          {:ok, _receipt} -> {:noreply, socket}
          {:error, reason} -> {:noreply, put_flash(socket, :error, Issho.Action.message(reason))}
        end
      end

  An agent: the action is a tool (`Issho.Tool`), among the others it is
  given (`Issho.Tools`, `Issho.MCP`):

      tools = Issho.Tools.room() ++ [MyApp.Actions.CheckItem]

  Your code: `invoke/5`, as anyone.

  ## What an action says

    * `name`, `description` and its arguments (`arg`, as a tool's): what
      it is, for people reading the code and for models;
    * `can`: what the policy must allow in its room (`:write`, the
      default; `:comment`, `:read`, or another of `Issho.Policy`'s);
    * `c:target/1`: its room, from its arguments (a page, a board): where
      the policy is asked, where it is seen done, and where an agent is
      paused or not;
    * `c:run/2`: the change, the app's own (an Ecto write, a document's
      transaction, another service's call), as the invocation's `by`;
    * `c:authorize/2`, optional: what the room's policy cannot say (the
      record is in this page; the person may set this property);
    * `c:summary/1`, optional: the result in words, for an agent;
    * `c:event/2`, optional: what the room's `"action.done"` event says
      of it, beyond its name and invocation (a small map).

  ## An invocation

  Each run of an action is an invocation (`Issho.Action.Invocation`): its
  id, the action, the room, who (`by`, and whom they act for), and the
  arguments. It is checked, in this order:

    1. its arguments, against what the action declares;
    2. the room's policy (`can`), and the action's own `c:authorize/2`;
    3. its id: run once (`:id`, or `invocation_id` from an agent); a
       retry with the same id and the same arguments gives the first
       one's receipt (`replayed: true`) and does nothing again; the same
       id with other arguments, an other action or by someone else is
       refused (`:id_reused`); one still running, `:in_progress`;
    4. the agent's pause or stop (`Issho.Work.guard/2`), right before the
       change: a paused agent changes nothing, and is told so.

  Done, it gives `{:ok, %Issho.Action.Receipt{}}`, and the room hears
  `"action.done"` (`Issho.Event`), by whoever did it. A failed change, a
  refusal or an interruption gives `{:error, reason}`, never a receipt:
  the next try with the same id runs again.

  The receipts of an instance are kept for `:action_keep` milliseconds
  (ten minutes), in the memory of the node that ran them: a retry that
  reaches another node runs again. Durable receipts are for later.

  ## What it does not do

  An action runs only your code: it never runs a LiveView's events, or
  anything a model writes. What can be undone is your app's to say, with
  an action of its own; a receipt is not a promise that it can be.
  """

  alias Issho.Action.{Invocation, Receipt, Receipts}
  alias Issho.{Agents, Config, Event, Events, Identity, Policy, Tool, Transaction, Work}

  @typedoc "Why an invocation did not run."
  @type reason ::
          {:invalid, String.t()}
          | :forbidden
          | {:interrupted, map()}
          | :in_progress
          | :id_reused
          | term()

  @doc "The room of the action, from its arguments."
  @callback target(args :: map()) :: String.t()

  @doc "The change, as the invocation's `by`: `{:ok, result}` or `{:error, reason}`."
  @callback run(args :: map(), Invocation.t()) :: {:ok, term()} | {:error, term()}

  @doc "What the policy must allow in the room: `:write` unless the action says."
  @callback can() :: Policy.action()

  @doc "Whether this person or agent may run it with these arguments, beyond the room's policy."
  @callback authorize(args :: map(), Identity.t()) :: :ok | {:error, term()}

  @doc "The result, for an agent: words, or a map or list as JSON."
  @callback summary(result :: term()) :: String.t() | map() | list()

  @doc "What the room's `\"action.done\"` event says of it, beyond its name and invocation."
  @callback event(args :: map(), result :: term()) :: map()

  @optional_callbacks authorize: 2, summary: 1, event: 2

  @doc false
  defmacro __using__(opts) do
    {can, opts} = Keyword.pop(opts, :can, :write)

    quote do
      use Issho.Tool, unquote(opts)
      @behaviour Issho.Action

      arg :invocation_id, :string,
        max_length: 64,
        description:
          "Optional. Your own id for this change: retried with the same id, it is done once."

      @impl Issho.Action
      def can, do: unquote(can)

      @impl Issho.Tool
      def call(args, ctx), do: Issho.Action.call(__MODULE__, args, ctx)
    end
  end

  @doc """
  Runs the action as `who` (an actor or an identity), with `input` (string
  or atom keys). Options: `:id` (the invocation's id, for retries; a new
  one unless given), `:on_behalf_of` and `:claims` (as a join's), and
  `:participant` (the agent's, to be paused in; found for an agent of
  `Issho.Agents` in the room).
  """
  @spec invoke(atom(), module(), map(), Issho.Actor.t() | Identity.t(), keyword()) ::
          {:ok, Receipt.t()} | {:error, reason()}
  def invoke(instance, action, input, who, opts \\ []) do
    identity = Identity.new(who, Keyword.take(opts, [:on_behalf_of, :claims]))

    with {:ok, args, given_id} <- cast(action, input),
         room = action.target(args),
         :ok <- permitted(instance, action, args, identity, room) do
      id = opts[:id] || given_id || Transaction.id()

      case Receipts.claim(instance, id, fingerprint(action, args, identity)) do
        {:ok, :new} ->
          invocation = %Invocation{
            id: id,
            action: action,
            room: room,
            by: identity,
            args: args,
            participant: opts[:participant] || participant(instance, identity, room)
          }

          execute(instance, invocation)

        {:ok, {:done, receipt}} ->
          {:ok, %{receipt | replayed: true}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Whether `who` may run the action with these arguments now: the same
  checks as `invoke/5` makes before it runs, and nothing run. For a
  button's disabled state and its reason, or a list of what an agent may
  do; the run checks again.
  """
  @spec allowed(atom(), module(), map(), Issho.Actor.t() | Identity.t(), keyword()) ::
          :ok | {:error, reason()}
  def allowed(instance, action, input, who, opts \\ []) do
    identity = Identity.new(who, Keyword.take(opts, [:on_behalf_of, :claims]))

    with {:ok, args, _id} <- cast(action, input),
         do: permitted(instance, action, args, identity, action.target(args))
  end

  @doc "The action's room, for these arguments (`c:target/1`), once they are what it declares."
  @spec room(module(), map()) :: {:ok, String.t()} | {:error, {:invalid, String.t()}}
  def room(action, input) do
    with {:ok, args, _id} <- cast(action, input), do: {:ok, action.target(args)}
  end

  @doc "A reason an invocation did not run, in words a person or a model reads."
  @spec message(reason()) :: String.t()
  def message({:invalid, text}), do: text
  def message(:in_progress), do: "That change is still being made: look again in a moment."

  def message(:id_reused),
    do: "That invocation_id was used for another change: give a new one for this change."

  def message(reason), do: reason |> Tool.Context.error() |> elem(1)

  @doc false
  # The action as an agent's tool: it joins the action's room (so it is
  # seen there, and can be paused there), and runs it as its context's
  # agent.
  @spec call(module(), map(), Tool.Context.t()) :: Tool.result()
  def call(action, args, %Tool.Context{} = ctx) do
    opts = Keyword.take(ctx.opts, [:on_behalf_of, :claims])

    with {:ok, room} <- room(action, args),
         {:ok, participant} <- Tool.Context.join(ctx, room),
         {:ok, receipt} <-
           invoke(ctx.instance, action, args, ctx.actor, [participant: participant] ++ opts) do
      {:ok, summary(action, receipt)}
    else
      {:error, reason} -> {:error, message(reason)}
    end
  end

  defp summary(action, %Receipt{result: result, replayed: replayed}) do
    text =
      cond do
        function_exported?(action, :summary, 1) -> action.summary(result)
        is_binary(result) or is_map(result) or is_list(result) -> result
        true -> "Done."
      end

    if replayed and is_binary(text),
      do: text <> " (Done before, with this invocation_id: not done again.)",
      else: text
  end

  defp cast(action, input) do
    case Tool.cast(action, input) do
      {:ok, args} ->
        {id, args} = Map.pop(args, :invocation_id)
        {:ok, args, id}

      {:error, text} ->
        {:error, {:invalid, text}}
    end
  end

  defp permitted(instance, action, args, identity, room) do
    Code.ensure_loaded(action)

    with :ok <- Policy.authorize(Config.get(instance).policy, identity, room, action.can()) do
      if function_exported?(action, :authorize, 2),
        do: action.authorize(args, identity),
        else: :ok
    end
  end

  # The same action, arguments and person: a retry, not another change.
  defp fingerprint(action, args, identity) do
    :crypto.hash(:sha256, :erlang.term_to_binary({action, args, identity.key}, [:deterministic]))
  end

  defp participant(instance, %Identity{kind: :agent, key: key}, room) do
    case Agents.participant(instance, key, room) do
      pid when is_pid(pid) -> pid
      _absent -> nil
    end
  end

  defp participant(_instance, _identity, _room), do: nil

  defp execute(instance, %Invocation{action: action} = invocation) do
    outcome =
      try do
        guard(invocation, fn -> action.run(invocation.args, invocation) end)
      catch
        kind, reason ->
          Receipts.release(instance, invocation.id)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case outcome do
      {:ok, result} ->
        receipt = %Receipt{
          id: invocation.id,
          action: action.name(),
          room: invocation.room,
          by: invocation.by,
          result: result,
          at: DateTime.utc_now()
        }

        Receipts.done(instance, invocation.id, receipt)
        done(instance, invocation, result)
        {:ok, receipt}

      {:error, _reason} = error ->
        Receipts.release(instance, invocation.id)
        error

      other ->
        Receipts.release(instance, invocation.id)
        raise ArgumentError, "#{inspect(action)}.run/2 returned #{inspect(other)}"
    end
  end

  defp guard(%Invocation{participant: nil}, fun), do: fun.()
  defp guard(%Invocation{participant: participant}, fun), do: Work.guard(participant, fun)

  # The room hears it done, by whoever did it.
  defp done(instance, %Invocation{action: action} = invocation, result) do
    data =
      if function_exported?(action, :event, 2),
        do: Map.new(action.event(invocation.args, result)),
        else: %{}

    event = %Event{
      name: "action.done",
      room: invocation.room,
      by: invocation.by,
      data: Map.merge(data, %{action: action.name(), invocation: invocation.id}),
      at: DateTime.utc_now()
    }

    Events.broadcast(Config.get(instance).pubsub, event)
  end
end
