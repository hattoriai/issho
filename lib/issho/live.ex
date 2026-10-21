if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Issho.Live do
    @moduledoc ~S"""
    A LiveView in a room: the same session as a browser's channel or an
    agent's process, in the LiveView's own process. Presence, awareness,
    the room's documents and the policy work the same; the room's events
    reach the LiveView's components with `send_update/2`, or the LiveView
    itself.

        live_session :default, on_mount: [Issho.Live] do

        # In a LiveView or one of its components, once connected:
        {:ok, _session} = Issho.Live.join(MyApp.Issho, current_user, "board:42")
        {:ok, snapshot} = Issho.Live.open("board:42", "board:42", notify: {MyComponent, "board"})

    A component named in `notify` gets `update/2` with an `:issho` assign
    for each event, `{event, key, payload}`:

      * `{"tx", document_id, accepted_transaction}`: a transaction accepted
        in a document it opened;
      * `{"aware", room, frame}`: the others' awareness;
      * `{"presence_diff", room, diff}`: people who came and went;
      * `{"bye", room, reason}`: the session ended (revoked, refused).

    `notify: :self` sends them to the LiveView as
    `{Issho.Live, event, key, payload}` messages instead.

    The components of a LiveView share one session per room: joining a
    room the LiveView is in already gives the same session.

    Join only in a connected LiveView (`connected?(socket)`): the static
    render has no process that lasts.
    """

    import Phoenix.LiveView, only: [attach_hook: 4, send_update: 2]

    alias Issho.{Authority, Identity, Policy, Session, Transaction}

    @mounted {__MODULE__, :mounted}

    @type target :: {module(), term()} | :self

    @doc false
    def on_mount(_arg, _params, _session, socket) do
      Process.put(@mounted, true)
      {:cont, attach_hook(socket, :issho_live, :handle_info, &__MODULE__.__handle_info__/2)}
    end

    @doc """
    Joins a room as an actor, from this LiveView, or gives the session the
    LiveView already has there. Options: `:can` (`:write`), `:claims`,
    `:on_behalf_of`.
    """
    @spec join(atom(), Issho.Actor.t(), String.t(), keyword()) ::
            {:ok, String.t()} | {:error, term()}
    def join(instance, actor, room, opts \\ []) do
      ensure_mounted!()

      case session(room) do
        %Session{session_id: id} ->
          {:ok, id}

        nil ->
          identity = Identity.new(actor, Keyword.take(opts, [:claims, :on_behalf_of]))

          with {:ok, session} <-
                 Session.join(instance, room, identity, Keyword.get(opts, :can, :write)) do
            put_session(session)
            {:ok, session.session_id}
          end
      end
    end

    @doc """
    Opens a document of the room. Options: `:notify`, a component
    (`{module, id}`) or `:self`, for its transactions and the room's events;
    and `:spec`, what the document is if this opens it first (see
    `Issho.Documents.open/4`).
    """
    @spec open(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
    def open(room, document_id, opts \\ []) do
      with {:ok, session} <- fetch(room),
           {:ok, snapshot, session} <-
             Session.open(session, document_id, [], Keyword.take(opts, [:spec])) do
        put_session(session)

        if target = opts[:notify] do
          subscribe(document_id, target)
          subscribe(room, target)
        end

        {:ok, snapshot}
      end
    end

    @doc "Sends the room's events to a component, or the LiveView, without opening a document."
    @spec subscribe(String.t(), target()) :: true
    def subscribe(key, target) do
      Process.put({__MODULE__, :targets, key}, MapSet.put(targets(key), target))
      true
    end

    @doc """
    Commits to an open document: a list of operations (on the document's
    latest revision) or a whole transaction.
    """
    @spec transact(String.t(), String.t(), [term()] | map()) :: {:ok, map()} | {:error, term()}
    def transact(room, document_id, ops) when is_list(ops) do
      with {:ok, session} <- fetch(room),
           {:ok, pid} <- document(session, document_id),
           {:ok, snapshot} <- Authority.snapshot(pid) do
        Session.transact(session, document_id, %{
          "id" => Transaction.id(),
          "epoch" => snapshot["epoch"],
          "base_revision" => snapshot["revision"],
          "ops" => ops
        })
      end
    end

    def transact(room, document_id, %{} = transaction) do
      with {:ok, session} <- fetch(room), do: Session.transact(session, document_id, transaction)
    end

    @doc "The document's current snapshot, from its authority."
    @spec read(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
    def read(room, document_id) do
      with {:ok, session} <- fetch(room),
           {:ok, pid} <- document(session, document_id),
           do: Authority.snapshot(pid)
    end

    @doc "Sets this session's awareness state (`nil` clears it)."
    @spec aware(String.t(), map() | nil) :: :ok | {:error, term()}
    def aware(room, state) do
      with {:ok, session} <- fetch(room),
           {:ok, session} <- Session.aware(session, state) do
        put_session(session)
        :ok
      end
    end

    @doc "The people of the room now: `Phoenix.Presence`'s list, by actor key."
    @spec people(String.t()) :: map()
    def people(room) do
      case fetch(room) do
        {:ok, session} -> Session.people(session)
        {:error, _} -> %{}
      end
    end

    @doc "The session id of this LiveView in the room, or `nil`."
    @spec session_id(String.t()) :: String.t() | nil
    def session_id(room) do
      case session(room) do
        %Session{session_id: id} -> id
        nil -> nil
      end
    end

    @doc false
    # The room's messages, as the on_mount hook takes them.
    def __handle_info__(message, socket) do
      case room_of(message) do
        nil ->
          {:cont, socket}

        room ->
          case session(room) do
            nil -> {:halt, socket}
            session -> {:halt, deliver(socket, session, Session.handle(session, message))}
          end
      end
    end

    defp deliver(socket, _session, {:push, "tx", %{"doc" => doc, "event" => event}, session}) do
      put_session(session)
      notify(doc, {"tx", doc, event})
      socket
    end

    defp deliver(socket, _session, {:push, event, payload, session}) do
      put_session(session)
      notify(session.room, {event, session.room, payload})
      socket
    end

    defp deliver(socket, _session, {:skip, next}) do
      put_session(next)
      socket
    end

    defp deliver(socket, session, {:stop, reason}) do
      Session.aware(session, nil)
      Process.delete({__MODULE__, :session, session.room})
      notify(session.room, {"bye", session.room, Atom.to_string(reason)})
      socket
    end

    defp notify(key, {event, key_of, payload}) do
      for target <- targets(key) do
        case target do
          :self -> send(self(), {__MODULE__, event, key_of, payload})
          {module, id} -> send_update(module, id: id, issho: {event, key_of, payload})
        end
      end
    end

    # The room a message of Issho's is about, if it is one.
    defp room_of({Issho, :transaction, document_id, _event}), do: Policy.room(document_id)
    defp room_of({Issho, :awareness, room, _frame}), do: room
    defp room_of({Issho, :revoke, room, _key}), do: room
    # Between the awareness processes of a room's nodes; sessions skip it.
    defp room_of({Issho, :awareness_hello, room}), do: room

    defp room_of(%Phoenix.Socket.Broadcast{topic: "issho:presence:" <> room}), do: room
    defp room_of(_message), do: nil

    defp fetch(room) do
      case session(room) do
        nil -> {:error, :not_joined}
        session -> {:ok, session}
      end
    end

    defp document(session, document_id) do
      case Map.fetch(session.documents, document_id) do
        {:ok, pid} -> {:ok, pid}
        :error -> {:error, :not_open}
      end
    end

    defp session(room), do: Process.get({__MODULE__, :session, room})

    defp put_session(%Session{room: room} = session),
      do: Process.put({__MODULE__, :session, room}, session)

    defp targets(key), do: Process.get({__MODULE__, :targets, key}, MapSet.new())

    defp ensure_mounted! do
      unless Process.get(@mounted) do
        raise ArgumentError, """
        Issho.Live needs its hook in the LiveView: `on_mount Issho.Live`, or \
        `live_session :default, on_mount: [Issho.Live]`\
        """
      end
    end
  end
end
