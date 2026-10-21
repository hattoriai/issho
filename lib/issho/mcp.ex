if Code.ensure_loaded?(Sake.Server) do
  defmodule Issho.MCP.Setup do
    @moduledoc ~S"""
    Issho's MCP settings for one endpoint, as a plug before it: which
    instance, and who its callers are in the rooms. An app can serve its
    tools on several endpoints, each with its own:

        pipeline :people_mcp do
          # Each person's own agent, acting on their behalf.
          plug Issho.MCP.Setup, agent: {MyApp.Collaboration, :assistant}
        end

        pipeline :bot_mcp do
          # The app's own bot, acting as itself.
          plug Issho.MCP.Setup, agent: {MyApp.Collaboration, :bot}
        end

    Options: `:instance` and `:agent`, as in `Issho.MCP.Session`. What a
    plug sets wins over the `config :issho, Issho.MCP` of the app.
    """

    @behaviour Plug

    @impl true
    def init(opts), do: Keyword.take(opts, [:instance, :agent])

    @impl true
    def call(conn, opts), do: Plug.Conn.assign(conn, :issho, opts)
  end

  defmodule Issho.MCP.Session do
    @moduledoc ~S"""
    Who an MCP caller is in Issho's rooms: the `Issho.Tool.Context` its
    tool calls run with. The one place where an MCP endpoint's
    authorization (Sake's, your own, or none) meets Issho: the agent and
    the options of its joins come from the call.

    The settings, in the app's config or from `Issho.MCP.Setup`:

        config :issho, Issho.MCP,
          instance: MyApp.Issho,
          agent: {MyApp.Collaboration, :agent},
          idle: 600_000

    `agent` is `{module, function}` or a function of one argument, called
    with the call's `Sake.Context` (its `scope` is the principal your
    endpoint's authorization put there; nil without one). It gives
    `{actor, opts}`: the agent, and the options of its joins
    (`:on_behalf_of`, `:claims`, `:can`):

        def agent(%Sake.Context{scope: %MyApp.User{} = user}),
          do: {%{id: "assistant:#{user.id}", name: "Assistant", kind: :agent}, on_behalf_of: user}

        def agent(%Sake.Context{scope: %MyApp.Service{} = service}),
          do: {%{id: "service:#{service.id}", name: service.name, kind: :service}, []}

    Without `agent`, the caller is an agent named for its MCP client
    ("Claude Code"): on behalf of the principal when the principal is an
    `Issho.Actor`, or acting as itself when there is none.
    """

    alias Issho.{Identity, Tool}

    @doc "The context a call's tools run with."
    @spec context(Sake.Context.t()) :: Tool.Context.t()
    def context(%Sake.Context{} = ctx) do
      instance =
        setting(ctx, :instance) ||
          raise ArgumentError,
                "Issho.MCP needs an instance: `config :issho, Issho.MCP, instance: MyApp.Issho`, or Issho.MCP.Setup"

      {actor, opts} = agent(ctx)

      Tool.Context.new(
        instance,
        actor,
        Keyword.put_new(opts, :idle, setting(ctx, :idle) || 600_000)
      )
    end

    @doc false
    # Runs an Issho tool for an MCP call.
    def run(tool, args, %Sake.Context{} = ctx), do: Issho.Tools.run(tool, args, context(ctx))

    defp agent(ctx) do
      case setting(ctx, :agent) do
        {module, function} -> apply(module, function, [ctx])
        function when is_function(function, 1) -> function.(ctx)
        nil -> default_agent(ctx)
      end
    end

    defp default_agent(ctx) do
      client = ctx.client_info || %{}
      name = client["title"] || client["name"] || "Agent"
      person = person(ctx.scope)
      who = if person, do: ":" <> person.key, else: ""

      actor = %{id: "agent:" <> slug(client["name"] || name) <> who, name: name, kind: :agent}
      {actor, if(person, do: [on_behalf_of: person], else: [])}
    end

    defp person(nil), do: nil

    defp person(scope) do
      Identity.new(scope)
    rescue
      _not_an_actor -> nil
    end

    defp slug(name),
      do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

    # An endpoint's own settings (Issho.MCP.Setup), else the app's.
    defp setting(ctx, key) do
      endpoint = (ctx.conn_assigns || %{})[:issho] || []
      Keyword.get(endpoint, key) || Keyword.get(Application.get_env(:issho, Issho.MCP, []), key)
    end
  end

  defmodule Issho.MCP do
    @moduledoc ~S"""
    Issho's tools over MCP, with [Sake](https://hex.pm/packages/sake): a
    `Sake.Server` of the tools you give, Issho's (`Issho.Tools.room/0`)
    and the components' (`Kotoba.Issho.tools/0`, `Hakushi.Issho.tools/0`),
    for any MCP client. The same tools serve your app's own model without
    MCP (`Issho.Tools`).

        defmodule MyApp.MCP do
          use Issho.MCP,
            name: "my-app",
            version: "1.0.0",
            tools: Issho.Tools.room() ++ Kotoba.Issho.tools() ++ Hakushi.Issho.tools()
        end

        # config/config.exs
        config :issho, Issho.MCP, instance: MyApp.Issho

    Serve it as your app serves MCP: over HTTP or stdio, with Sake's
    authorization, your own, or none, on its own endpoint or mounted in
    your own server (`mount MyApp.MCP`). Who a caller is in the rooms:
    `Issho.MCP.Session`.

    Options: those of `use Sake.Server` (`:name`, `:version`,
    `:instructions`...), and `:tools`, a list of `Issho.Tool` modules.
    Sake is an optional dependency of Issho: add `{:sake, "~> 0.4"}` to
    serve MCP.
    """

    @doc false
    defmacro __using__(opts) do
      {tools, server} = Keyword.pop(opts, :tools, [])

      quote do
        use Sake.Server, unquote(server)
        tools(Issho.MCP.__wrap__(__MODULE__, unquote(tools)))
      end
    end

    @doc false
    # A Sake tool for each Issho tool, under the server's module.
    def __wrap__(server, tools) do
      for tool <- tools do
        module = Module.concat([server, Tools, Macro.camelize(tool.name())])

        contents =
          quote do
            alias Issho.MCP.Session

            # The arguments as the client sent them (Sake 0.5): an Issho
            # tool casts them itself (Issho.Tool), and an older Sake, which
            # ignores the option, fills what was left out with nil.
            use Sake.Tool,
              name: unquote(tool.name()),
              description: unquote(tool.description()),
              input_schema: unquote(Macro.escape(tool.input_schema())),
              annotations: unquote(tool.annotations()),
              absent: :omit

            @impl true
            def execute(args, ctx), do: Session.run(unquote(tool), args, ctx)
          end

        Module.create(module, contents, Macro.Env.location(__ENV__))
        module
      end
    end
  end
end
