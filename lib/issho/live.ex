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

    ## Grants: rooms the browser joins

    A component whose browser half joins the room itself (a text editor,
    which applies its own changes in the browser) needs a grant: a short
    token for the room, signed by the LiveView for the actor it
    authenticated. `grant/4` signs it and remembers it, and the hook
    renews it when the browser asks (the `"issho:grant"` event, with the
    room), after asking the policy again, so that a person whose access
    went away gets no new grant. One grant serves every component of the
    page in that room.

        grant = Issho.Live.grant(MyApp.Issho, current_user, "notebook:7", can: :write)

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

      socket =
        socket
        |> attach_hook(:issho_live, :handle_info, &__MODULE__.__handle_info__/2)
        |> attach_hook(:issho_grant, :handle_event, &__MODULE__.__handle_event__/3)

      {:cont, socket}
    end

    @doc """
    A grant for the browser to join the room as the actor: `%{"room",
    "token", "can", "self", "socket", "max_channels"}`, for a component's
    browser half. The LiveView renews it when the browser asks. Options:
    `:can` (`:write` or `:read`), `:claims`, `:on_behalf_of`, `:socket`
    (the Issho socket's path, `"/issho/socket"`) and `:max_channels`
    (that socket's `:max_channels_per_transport`, 100).
    """
    @spec grant(atom(), Issho.Actor.t(), String.t(), keyword()) :: map()
    def grant(instance, actor, room, opts \\ []) when is_binary(room) do
      ensure_mounted!()
      Process.put({__MODULE__, :grant, room}, {instance, actor, opts})
      sign(instance, actor, room, opts)
    end

    defp sign(instance, actor, room, opts) do
      identity = Identity.new(actor, Keyword.take(opts, [:claims, :on_behalf_of]))
      can = Keyword.get(opts, :can, :write)

      %{
        "room" => room,
        "token" => Issho.Token.sign(instance, identity, room, can: can),
        "can" => Atom.to_string(can),
        "self" => identity.key,
        "socket" => Keyword.get(opts, :socket, "/issho/socket"),
        "max_channels" => Keyword.get(opts, :max_channels, 100)
      }
    end

    @doc false
    # A grant again, for a room this LiveView granted, if the policy still lets the actor in.
    def __handle_event__("issho:grant", %{"room" => room}, socket) when is_binary(room) do
      reply =
        with {instance, actor, opts} <- Process.get({__MODULE__, :grant, room}),
             identity = Identity.new(actor, Keyword.take(opts, [:claims, :on_behalf_of])),
             :ok <-
               Policy.authorize(Issho.Config.get(instance).policy, identity, room, :join) do
          sign(instance, actor, room, opts)
        else
          _ -> %{}
        end

      {:halt, reply, socket}
    end

    def __handle_event__(_event, _params, socket), do: {:cont, socket}

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
        Process.put({__MODULE__, :aware, room}, state)
        :ok
      end
    end

    @doc """
    Merges keys into this session's awareness state: for the components of
    a LiveView that share its session in a room, each setting its own
    keys (a grid its place, another component its own key).
    """
    @spec merge(String.t(), map()) :: :ok | {:error, term()}
    def merge(room, changes) when is_map(changes),
      do: aware(room, Map.merge(awareness(room), changes))

    @doc "This session's own awareness state (an empty map for none)."
    @spec awareness(String.t()) :: map()
    def awareness(room), do: Process.get({__MODULE__, :aware, room}) || %{}

    @doc """
    The awareness states of the room's sessions, from every node:
    `%{session_id => %{"key" => actor_key, "state" => state}}`, for a
    component that draws the others itself.
    """
    @spec states(String.t()) :: map()
    def states(room) do
      case fetch(room) do
        {:ok, session} -> Issho.Awareness.states(session.instance, room)
        {:error, _} -> %{}
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
      Process.delete({__MODULE__, :aware, session.room})
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
