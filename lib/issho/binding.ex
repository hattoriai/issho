defmodule Issho.Binding do
  @moduledoc """
  What a component brings to Issho: its engine (`Issho.Engine`) and its
  place format (`Issho.Place`). The browser's half of a binding brings the
  rest: drawing places, and reading and applying a view for following.

      # In Kotoba, compiled only when Issho is present:
      if Code.ensure_loaded?(Issho.Binding) do
        defmodule Kotoba.Issho do
          use Issho.Binding, engine: Kotoba.Issho.Engine, place: Kotoba.Issho.Place
        end
      end

  A binding module is what a policy names as a document's engine
  (`%{engine: Kotoba.Issho, ...}`): it delegates the engine's callbacks,
  and `place/0` names the place module.
  """

  @doc false
  defmacro __using__(opts) do
    engine = Keyword.fetch!(opts, :engine)
    place = Keyword.get(opts, :place)

    quote bind_quoted: [engine: engine, place: place] do
      @behaviour Issho.Engine

      @doc false
      def __issho_binding__, do: true

      @doc "The place module of this binding, or `nil`."
      def place, do: unquote(place)

      @impl Issho.Engine
      defdelegate name(), to: engine
      @impl Issho.Engine
      defdelegate version(), to: engine
      @impl Issho.Engine
      defdelegate init(initial, opts), to: engine
      @impl Issho.Engine
      defdelegate apply(state, ops, opts), to: engine

      @impl Issho.Engine
      def validate(state, opts), do: Issho.Engine.validate(unquote(engine), state, opts)

      @impl Issho.Engine
      def snapshot(state), do: Issho.Engine.snapshot(unquote(engine), state)
    end
  end

  @doc false
  # The place module of an engine or a binding, or nil.
  @spec place(module()) :: module() | nil
  def place(module) do
    if function_exported?(module, :__issho_binding__, 0), do: module.place()
  end
end
