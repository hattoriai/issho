defmodule IsshoTest.Policy do
  @moduledoc false
  # The test app's policy: rooms "board:*" are maps; an actor whose key is
  # in the denied set may do nothing, and "readonly:*" rooms refuse :write.
  @behaviour Issho.Policy

  def deny(key), do: :persistent_term.put({__MODULE__, key}, true)
  def allow(key), do: :persistent_term.erase({__MODULE__, key})
  defp denied?(key), do: :persistent_term.get({__MODULE__, key}, false)

  @impl true
  def authorize(identity, room, action) do
    cond do
      denied?(identity.key) -> {:error, :forbidden}
      String.starts_with?(room, "readonly:") and action in [:write, :lock] -> {:error, :forbidden}
      true -> :ok
    end
  end

  @impl true
  def document(_identity, "missing:" <> _), do: {:error, :not_found}

  def document(_identity, id) do
    {:ok, %{engine: IsshoTest.Binding, initial: %{"title" => "Untitled", "doc" => id}}}
  end
end

defmodule IsshoTest.Place do
  @moduledoc false
  # A place in a map: a key path.
  @behaviour Issho.Place

  @impl true
  def validate(%{"path" => path}) when is_list(path), do: :ok
  def validate(_place), do: {:error, :invalid_place}
end

defmodule IsshoTest.Binding do
  @moduledoc false
  use Issho.Binding, engine: Issho.Engine.Map, place: IsshoTest.Place
end

defmodule IsshoTest.Channel do
  @moduledoc false
  use Issho.Channel, instance: IsshoTest.Issho
end

defmodule IsshoTest.Socket do
  @moduledoc false
  use Phoenix.Socket
  channel "issho:*", IsshoTest.Channel
  @impl true
  def connect(_params, socket, _info), do: {:ok, socket}
  @impl true
  def id(_socket), do: nil
end

defmodule IsshoTest.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :issho
  socket "/issho/socket", IsshoTest.Socket
end

defmodule IsshoTest.LiveEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :issho
  socket "/issho/socket", IsshoTest.Socket, websocket: true, longpoll: false
end
