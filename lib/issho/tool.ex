defmodule Issho.Tool do
  @moduledoc ~S"""
  A tool an agent uses in Issho's rooms, however it reaches your app: an
  MCP client (`Issho.MCP`), your app's own model through an API
  (`Issho.Tools`), or whatever comes next. A tool says what it does and
  what it takes, as a JSON Schema; it runs as the agent of an
  `Issho.Tool.Context`, under your policy, as anyone in a room does.

  Issho's room tools are `Issho.Tools.room/0`; a component brings its own
  (`Kotoba.Issho.tools/0`, `Hakushi.Issho.tools/0`).

      defmodule MyApp.Tools.Rename do
        use Issho.Tool,
          name: "rename_board",
          description: "Renames a board.",
          annotations: [idempotent: true]

        arg :board, :string, required: true
        arg :title, :string, required: true, max_length: 120

        @impl true
        def call(%{board: board, title: title}, ctx) do
          with {:ok, agent, _doc, _snapshot} <- Issho.Tool.Context.open(ctx, board) do
            ops = [%{"op" => "set", "path" => ["title"], "value" => title}]

            case Issho.Participant.transact(agent, board, ops) do
              {:ok, _receipt} -> {:ok, "Renamed."}
              {:error, reason} -> Issho.Tool.Context.error(reason)
            end
          end
        end
      end

  `arg name, type, opts` declares an argument; the types are `:string`,
  `:integer`, `:number`, `:boolean`, `:any`, `{:array, type}`,
  `{:enum, values}` and `{:object, [{name, type, opts}]}`, and the options
  `required`, `description`, `min`, `max`, `min_length` and `max_length`.
  `call/2` gets the declared arguments with atom keys, the ones given.

  `call/2` gives `{:ok, result}` (text, or a map or list as JSON) or
  `{:error, text}`: what went wrong, in words the model reads.
  """

  @type result :: {:ok, String.t() | map() | list()} | {:error, String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback annotations() :: keyword()
  @callback call(args :: map(), Issho.Tool.Context.t()) :: result()

  @doc false
  defmacro __using__(opts) do
    quote do
      @behaviour Issho.Tool
      import Issho.Tool, only: [arg: 2, arg: 3]
      Module.register_attribute(__MODULE__, :issho_args, accumulate: true)
      @issho_tool unquote(opts)
      @before_compile Issho.Tool
    end
  end

  @doc "Declares an argument of the tool."
  defmacro arg(name, type, opts \\ []) do
    quote do: @issho_args({unquote(name), unquote(type), unquote(opts)})
  end

  @doc false
  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :issho_tool)
    args = env.module |> Module.get_attribute(:issho_args) |> Enum.reverse()
    name = Keyword.fetch!(opts, :name)
    description = opts |> Keyword.fetch!(:description) |> String.trim()

    quote do
      @impl Issho.Tool
      def name, do: unquote(name)
      @impl Issho.Tool
      def description, do: unquote(description)
      @impl Issho.Tool
      def input_schema, do: unquote(Macro.escape(Issho.Tool.schema(args)))
      @impl Issho.Tool
      def annotations, do: unquote(Keyword.get(opts, :annotations, []))
      @doc false
      def __args__, do: unquote(Macro.escape(args))
    end
  end

  @doc false
  # The JSON Schema of arguments.
  def schema(args) do
    required = for {name, _type, opts} <- args, opts[:required], do: to_string(name)

    %{
      "type" => "object",
      "properties" =>
        Map.new(args, fn {name, type, opts} -> {to_string(name), property(type, opts)} end)
    }
    |> then(&if(required == [], do: &1, else: Map.put(&1, "required", required)))
  end

  defp property(type, opts) do
    type
    |> type()
    |> put("description", opts[:description])
    |> put("minimum", opts[:min])
    |> put("maximum", opts[:max])
    |> put("minLength", opts[:min_length])
    |> put("maxLength", opts[:max_length])
  end

  defp type(:any), do: %{}

  defp type(scalar) when scalar in [:string, :integer, :number, :boolean],
    do: %{"type" => to_string(scalar)}

  defp type({:array, item}), do: %{"type" => "array", "items" => type(item)}
  defp type({:enum, values}), do: %{"type" => "string", "enum" => values}
  defp type({:object, fields}), do: schema(fields)

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  @doc false
  # The arguments a tool declared, from what was given (string or atom
  # keys), with the declared atom keys; or what is wrong with them.
  def cast(tool, given) when is_map(given) do
    Enum.reduce_while(tool.__args__(), {:ok, %{}}, fn {name, type, opts}, {:ok, acc} ->
      case {fetch(given, name), opts[:required]} do
        {:error, true} -> {:halt, {:error, "#{name} is required."}}
        {:error, _optional} -> {:cont, {:ok, acc}}
        {{:ok, nil}, _required} -> {:cont, {:ok, acc}}
        {{:ok, value}, _required} -> check(name, value, type, opts, acc)
      end
    end)
  end

  def cast(_tool, _given), do: {:error, "The arguments are an object."}

  defp fetch(given, name) do
    case Map.fetch(given, to_string(name)) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(given, name)
    end
  end

  defp check(name, value, type, opts, acc) do
    if valid?(value, type, opts),
      do: {:cont, {:ok, Map.put(acc, name, cast_value(value, type))}},
      else: {:halt, {:error, "#{name} is not #{describe(type)}."}}
  end

  defp valid?(_value, :any, _opts), do: true

  defp valid?(value, :string, opts),
    do:
      is_binary(value) and String.length(value) <= (opts[:max_length] || :infinity) and
        String.length(value) >= (opts[:min_length] || 0)

  defp valid?(value, :integer, opts), do: is_integer(value) and in_range?(value, opts)
  defp valid?(value, :number, opts), do: is_number(value) and in_range?(value, opts)
  defp valid?(value, :boolean, _opts), do: is_boolean(value)
  defp valid?(value, {:enum, values}, _opts), do: value in values

  defp valid?(value, {:array, item}, _opts),
    do: is_list(value) and Enum.all?(value, &valid?(&1, item, []))

  defp valid?(value, {:object, fields}, _opts) do
    is_map(value) and
      Enum.all?(fields, fn {name, type, opts} ->
        case fetch(value, name) do
          {:ok, nil} -> opts[:required] != true
          {:ok, field} -> valid?(field, type, opts)
          :error -> opts[:required] != true
        end
      end)
  end

  defp in_range?(value, opts),
    do: value >= (opts[:min] || value) and value <= (opts[:max] || value)

  # An object's declared fields, with atom keys, as the tool's own arguments
  # are: a field given as null is not given, as an argument is not (an MCP
  # layer may fill each declared field with null).
  defp cast_value(value, {:object, fields}) do
    for {name, type, _opts} <- fields,
        {:ok, field} when not is_nil(field) <- [fetch(value, name)],
        into: %{},
        do: {name, cast_value(field, type)}
  end

  defp cast_value(value, {:array, item}), do: Enum.map(value, &cast_value(&1, item))
  defp cast_value(value, _type), do: value

  defp describe(:any), do: "a value"
  defp describe({:array, item}), do: "a list of #{describe(item)}"
  defp describe({:enum, values}), do: "one of #{Enum.join(values, ", ")}"

  defp describe({:object, fields}) do
    case for {name, _type, opts} <- fields, opts[:required], do: name do
      [] -> "an object"
      required -> "an object with #{Enum.join(required, ", ")}"
    end
  end

  defp describe(:integer), do: "a whole number in range"
  defp describe(:number), do: "a number in range"
  defp describe(:string), do: "text of the right length"
  defp describe(:boolean), do: "true or false"
end

defmodule Issho.Tool.Context do
  @moduledoc ~S"""
  Who runs a tool: the agent (an `Issho.Actor`), the options of its joins
  (`:on_behalf_of`, `:claims`, `:can`), and the instance. A front end
  makes it from its caller: `Issho.MCP` from an MCP call, your code from
  the user your app's model works for.

      ctx = Issho.Tool.Context.new(MyApp.Issho, %{id: "assistant:#{user.id}", name: "Assistant", kind: :agent},
        on_behalf_of: user)

  The agent joins the rooms it works in and stays between calls, until it
  leaves or has been idle for `:idle` milliseconds (`Issho.Agents`).
  """

  alias Issho.{Agents, Identity}

  @enforce_keys [:instance, :actor]
  defstruct [:instance, :actor, opts: [], idle: 600_000]

  @type t :: %__MODULE__{
          instance: atom(),
          actor: Issho.Actor.t(),
          opts: keyword(),
          idle: pos_integer()
        }

  @doc "A context: the instance, the agent, and `:on_behalf_of`, `:claims`, `:can` and `:idle`."
  @spec new(atom(), Issho.Actor.t(), keyword()) :: t()
  def new(instance, actor, opts \\ []) do
    %__MODULE__{
      instance: instance,
      actor: actor,
      opts: Keyword.take(opts, [:on_behalf_of, :claims, :can]),
      idle: Keyword.get(opts, :idle, 600_000)
    }
  end

  @doc "The agent's participant in the room, joining it if it is not there."
  @spec join(t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def join(%__MODULE__{} = ctx, room) when is_binary(room),
    do: Agents.join(ctx.instance, ctx.actor, room, Keyword.put(ctx.opts, :idle, ctx.idle))

  @doc "The agent's participant in the room, with the document (the room unless given) open."
  @spec open(t(), String.t(), String.t() | nil) ::
          {:ok, pid(), String.t(), map()} | {:error, term()}
  def open(%__MODULE__{} = ctx, room, document \\ nil) do
    document = document || room

    with {:ok, participant} <- join(ctx, room),
         {:ok, snapshot} <- Issho.Participant.open(participant, document),
         do: {:ok, participant, document, snapshot}
  end

  @doc "The agent's key in the rooms."
  @spec key(t()) :: String.t()
  def key(%__MODULE__{actor: actor}), do: Identity.new(actor).key

  @doc "Takes the agent out of the room."
  @spec leave(t(), String.t()) :: :ok
  def leave(%__MODULE__{} = ctx, room), do: Agents.leave(ctx.instance, key(ctx), room)

  @doc "Keeps a value for the agent in the room, for its later calls."
  @spec remember(t(), String.t(), term(), term()) :: :ok | {:error, :not_there}
  def remember(%__MODULE__{} = ctx, room, name, value),
    do: Agents.put(ctx.instance, key(ctx), room, name, value)

  @doc "A value the agent kept in the room, or `nil`."
  @spec recall(t(), String.t(), term()) :: term()
  def recall(%__MODULE__{} = ctx, room, name), do: Agents.get(ctx.instance, key(ctx), room, name)

  @doc "A tool's error, as words the model reads."
  @spec error(term()) :: {:error, String.t()}
  def error(:forbidden), do: {:error, "The room's policy does not allow this."}
  def error(:read_only), do: {:error, "You may only read in this room."}
  def error(:not_open), do: {:error, "Open the document first."}
  def error(:other_room), do: {:error, "That document is not in this room."}
  def error(:no_documents), do: {:error, "There is no such document open in this room."}
  def error({:interrupted, by}), do: {:error, Issho.Work.message(by)}
  def error({:stale, details}), do: {:error, stale(details)}
  def error(:invalid_version), do: {:error, "That is not a version: give the one a read gave."}
  def error(reason) when is_binary(reason), do: {:error, reason}
  def error(reason), do: {:error, "Refused: #{inspect(reason)}"}

  # What changed since the version the agent saw, in words, and the
  # version to read again.
  defp stale(%{"version" => version} = details) do
    since =
      case details do
        %{"complete" => true, "count" => count, "changes" => changes} ->
          by = changes |> Enum.map(& &1["author"]) |> Enum.uniq() |> Enum.join(", ")
          " #{count} #{if count == 1, do: "change", else: "changes"} since, by #{by}."

        %{"count" => count} when is_integer(count) ->
          " #{count} changes since, the last by #{details["changes"] |> List.last() |> Map.get("author")}."

        _other ->
          " Which changes, Issho no longer knows."
      end

    "Not changed: the document is no longer the version you read." <>
      since <>
      " It is now at #{version}: read it again, then make your change on what it says now" <>
      " (if_revision: #{version})."
  end
end
