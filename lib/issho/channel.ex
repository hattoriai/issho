defmodule Issho.Channel do
  @moduledoc ~S"""
  The channel a browser joins a room on: one per room per tab, on one
  socket for the whole page.

      defmodule MyAppWeb.IsshoChannel do
        use Issho.Channel, instance: MyApp.Issho
      end

      defmodule MyAppWeb.IsshoSocket do
        use Phoenix.Socket
        channel "issho:*", MyAppWeb.IsshoChannel
        def connect(_params, socket, _info), do: {:ok, socket}
        def id(_socket), do: nil
      end

      # In the endpoint:
      socket "/issho/socket", MyAppWeb.IsshoSocket, websocket: [max_frame_size: 1_000_000]

  The topic is `"issho:" <> room`, and the join carries a token signed by
  your LiveView (`Issho.Token.sign/4`). The token says who the actor is
  and what it may do; the policy (`Issho.Policy`) is asked on join, on
  every message from the browser, and before each change to a document
  goes out to it.

  ## Messages

  From the browser, each with a reply:

    * `"open"`, `%{"doc" => id, "pending" => [transaction ids]}`: opens a
      document of the room; replies its snapshot, and which pending
      transactions (an offline queue's) were already accepted;
    * `"tx"`, `%{"doc" => id, "tx" => transaction}`: commits a transaction
      (`Issho.Transaction`); replies its revision;
    * `"aware"`, a state or `nil`: the session's awareness
      (`Issho.Awareness`);
    * `"content"`, `%{"doc" => id, "epoch" => e, "revision" => r}`: checks
      a revision exists, for a form that publishes it;
    * `"interrupt"`, `%{"agent" => key, "action" => "pause" | "resume" |
      "stop"}`: pauses, resumes or stops an agent at work in the room
      (`Issho.Work`), for the person it acts for, or whomever the policy
      allows `:interrupt`.

  To the browser: `"presence_state"` once, `"presence_diff"`, `"tx"` (a
  transaction accepted in an open document), `"aware"` (a frame of the
  others' states) and, when the session ends, `"bye"` with its reason.
  """

  alias Issho.{Config, Session, Token}

  defmacro __using__(opts) do
    instance = Keyword.fetch!(opts, :instance)

    quote do
      use Phoenix.Channel

      @impl Phoenix.Channel
      def join("issho:" <> room, params, socket),
        do: Issho.Channel.join(unquote(instance), room, params, socket)

      @impl Phoenix.Channel
      def handle_in(event, payload, socket), do: Issho.Channel.handle_in(event, payload, socket)

      @impl Phoenix.Channel
      def handle_info(message, socket), do: Issho.Channel.handle_info(message, socket)
    end
  end

  @doc false
  def join(instance, room, %{"token" => token}, socket) when is_binary(token) do
    with {:ok, identity, can} <- Token.verify(instance, token, room),
         {:ok, session} <- Session.join(instance, room, identity, can) do
      send(self(), :issho_after_join)

      {:ok, %{"session" => session.session_id, "can" => Atom.to_string(can)},
       Phoenix.Socket.assign(socket, :issho, session)}
    else
      {:error, :expired} -> {:error, %{"reason" => "expired"}}
      {:error, _reason} -> {:error, %{"reason" => "forbidden"}}
    end
  end

  def join(_instance, _room, _params, _socket), do: {:error, %{"reason" => "invalid_join"}}

  @doc false
  def handle_in(event, payload, socket) do
    session = socket.assigns.issho
    config = Config.get(session.instance)

    if byte_size(JSON.encode!(payload)) > config.max_message_bytes,
      do: {:reply, {:error, %{"reason" => "too_large"}}, socket},
      else: dispatch(event, payload, session, socket)
  end

  defp dispatch("open", %{"doc" => doc} = payload, session, socket) when is_binary(doc) do
    case Session.open(session, doc, Map.get(payload, "pending", [])) do
      {:ok, snapshot, session} ->
        {:reply, {:ok, snapshot}, Phoenix.Socket.assign(socket, :issho, session)}

      {:error, reason} ->
        reply_error(reason, socket)
    end
  end

  defp dispatch("tx", %{"doc" => doc, "tx" => tx}, session, socket) when is_binary(doc) do
    case Session.transact(session, doc, tx) do
      {:ok, receipt} -> {:reply, {:ok, receipt}, socket}
      {:error, reason} -> reply_error(reason, socket)
    end
  end

  defp dispatch("aware", state, session, socket) do
    case Session.aware(session, normalize(state)) do
      {:ok, session} -> {:reply, :ok, Phoenix.Socket.assign(socket, :issho, session)}
      {:error, reason} -> reply_error(reason, socket)
    end
  end

  defp dispatch("content", %{"doc" => doc, "epoch" => epoch, "revision" => rev}, session, socket) do
    with {:ok, pid} <- Map.fetch(session.documents, doc),
         {:ok, _content} <- Issho.Authority.content_at(pid, epoch, rev) do
      {:reply, :ok, socket}
    else
      :error -> reply_error(:not_open, socket)
      {:error, reason} -> reply_error(reason, socket)
    end
  end

  defp dispatch("interrupt", %{"agent" => key, "action" => action}, session, socket)
       when is_binary(key) and action in ["pause", "resume", "stop"] do
    case Session.interrupt(session, key, String.to_existing_atom(action)) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> reply_error(reason, socket)
    end
  end

  defp dispatch(_event, _payload, _session, socket), do: reply_error(:unknown_event, socket)

  # "aware" carries the state itself; an empty payload clears it.
  defp normalize(%{"state" => state}), do: state
  defp normalize(state) when state == %{}, do: nil
  defp normalize(state), do: state

  defp reply_error(reason, socket),
    do: {:reply, {:error, %{"reason" => reason_text(reason)}}, socket}

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(_reason), do: "error"

  @doc false
  def handle_info(:issho_after_join, socket) do
    Phoenix.Channel.push(socket, "presence_state", Session.people(socket.assigns.issho))
    {:noreply, socket}
  end

  def handle_info(message, socket) do
    case Session.handle(socket.assigns.issho, message) do
      {:push, event, payload, session} ->
        Phoenix.Channel.push(socket, event, payload)
        {:noreply, Phoenix.Socket.assign(socket, :issho, session)}

      {:skip, session} ->
        {:noreply, Phoenix.Socket.assign(socket, :issho, session)}

      {:stop, reason} ->
        Phoenix.Channel.push(socket, "bye", %{"reason" => Atom.to_string(reason)})
        {:stop, :normal, socket}
    end
  end
end
