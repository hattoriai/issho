if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Issho.Live.Comments do
    @moduledoc ~S"""
    The threads of comments of a room, on the page: a panel of the open
    and resolved threads, each with its comments, replies, reactions, and
    a composer, and a mark at each thread's place, drawn where its
    component locates it. Render it with `Issho.Components.comments/1`, in
    a LiveView that is in the room (`Issho.Live.join/4`).

    Everything goes through the LiveView, as the person it is in the room:
    their comments are theirs, at the server's time, under your policy's
    `:comment`. A new comment goes on what the person selected in a
    component of the page (their place), or on the page.
    """

    use Phoenix.LiveComponent

    alias Issho.{Color, Comments, Live}
    alias Issho.Comments.Ops
    alias Issho.Engine.Comments, as: Engine

    @reactions ["👍", "❤️", "🎉", "👀"]

    @impl true
    def mount(socket) do
      {:ok,
       assign(socket,
         joined: false,
         threads: [],
         candidates: [],
         revision: nil,
         status: "open",
         focused: nil,
         editing: nil,
         selection: nil,
         error: nil,
         drafts: 0,
         me: nil
       )}
    end

    @impl true
    def update(%{issho: {"tx", _document, event}}, socket), do: {:ok, transaction(socket, event)}

    def update(%{issho: {"aware", _room, _frame}}, socket),
      do: {:ok, assign(socket, :selection, selection(socket.assigns.room, socket.assigns.me))}

    # People came or went: whom the @ offers.
    def update(%{issho: {"presence_diff", _room, _diff}}, socket),
      do: {:ok, assign(socket, :candidates, candidates(socket))}

    def update(%{issho: _other}, socket), do: {:ok, socket}

    def update(assigns, socket) do
      socket =
        socket
        |> assign(Map.drop(assigns, [:flash]))
        |> assign_new(:mentionable, fn -> [] end)
        |> assign_new(:input, fn -> [] end)
        |> assign_new(:read, fn -> nil end)
        |> assign_new(:marks, fn -> true end)
        |> assign_new(:place, fn -> [] end)
        |> assign_new(:class, fn -> nil end)

      socket = if socket.assigns.joined, do: socket, else: open(socket)
      {:ok, assign(socket, :candidates, candidates(socket))}
    end

    # The room's comments, open in the LiveView's session, if it is in the room.
    defp open(socket) do
      room = socket.assigns.room

      with %Issho.Identity{} = me <- Live.identity(room),
           {:ok, %{"state" => %{"threads" => threads}, "revision" => revision}} <-
             Live.open(room, Comments.document(room), notify: {__MODULE__, socket.assigns.id}) do
        assign(socket,
          joined: true,
          me: me,
          threads: threads,
          revision: revision,
          selection: selection(room, me)
        )
      else
        _ -> socket
      end
    end

    # A transaction of the comments: the threads after it; one the
    # component has, skipped; after one it missed, read again.
    defp transaction(socket, %{"revision" => revision, "ops" => ops} = event) do
      seen = socket.assigns.revision

      cond do
        seen == nil or revision <= seen ->
          socket

        revision == seen + 1 ->
          {:ok, state} =
            Engine.apply(%{"threads" => socket.assigns.threads}, ops, author: event["author"])

          assign(socket, threads: state["threads"], revision: revision)

        true ->
          room = socket.assigns.room

          {:ok, %{"state" => %{"threads" => threads}, "revision" => now}} =
            Live.read(room, Comments.document(room))

          assign(socket, threads: threads, revision: now)
      end
    end

    # What the person selected in a component of the page, from their
    # browsers' states: the place a new comment goes on.
    defp selection(_room, nil), do: nil

    defp selection(room, me) do
      comments = Comments.document(room)

      room
      |> Live.states()
      |> Enum.find_value(fn
        {_session, %{"key" => key, "state" => %{"place" => %{"doc" => doc} = place}}}
        when key == me.key and doc != comments ->
          place

        _ ->
          nil
      end)
    end

    @impl true
    def handle_event("status", %{"status" => status}, socket) when status in ["open", "resolved"],
      do: {:noreply, assign(socket, status: status, focused: nil)}

    def handle_event("focus", %{"thread" => id}, socket) do
      socket = assign(socket, focused: id, editing: nil)

      socket =
        case find(socket.assigns.threads, id) do
          %{"status" => status, "place" => place} ->
            socket = assign(socket, :status, status)
            if place, do: push_event(socket, "issho:comments:show", place), else: socket

          nil ->
            socket
        end

      {:noreply, socket}
    end

    def handle_event("unfocus", _params, socket), do: {:noreply, assign(socket, focused: nil)}

    def handle_event("start", params, socket) do
      place = if params["where"] == "selection", do: socket.assigns.selection
      %{body: body, mentions: mentions} = read(socket, params)
      {op, ids} = Ops.start(socket.assigns.me, place, body, mentions: mentions)

      case commit(socket, op) do
        {:ok, socket} -> {:noreply, assign(socket, focused: ids.thread, status: "open")}
        {:error, socket} -> {:noreply, socket}
      end
    end

    def handle_event("reply", %{"thread" => thread} = params, socket) do
      %{body: body, mentions: mentions} = read(socket, params)
      {op, _ids} = Ops.reply(socket.assigns.me, thread, body, mentions: mentions)
      {:noreply, socket |> commit(op) |> elem(1)}
    end

    def handle_event("edit", %{"thread" => thread, "comment" => comment}, socket),
      do: {:noreply, assign(socket, editing: {thread, comment}, focused: thread)}

    def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, editing: nil)}

    def handle_event("save", %{"thread" => thread, "comment" => comment} = params, socket) do
      %{body: body, mentions: mentions} = read(socket, params)
      op = Ops.edit(thread, comment, body, mentions: mentions)

      case commit(socket, op) do
        {:ok, socket} -> {:noreply, assign(socket, editing: nil)}
        {:error, socket} -> {:noreply, socket}
      end
    end

    def handle_event("delete", %{"thread" => thread, "comment" => comment}, socket),
      do: {:noreply, socket |> commit(Ops.delete(thread, comment)) |> elem(1)}

    def handle_event("react", %{"thread" => thread, "comment" => cid, "emoji" => emoji}, socket) do
      me = socket.assigns.me.key
      comments = (find(socket.assigns.threads, thread) || %{})["comments"] || []
      comment = find(comments, cid)

      op =
        if comment && me in Map.get(comment["reactions"], emoji, []),
          do: Ops.unreact(thread, cid, emoji),
          else: Ops.react(thread, cid, emoji)

      {:noreply, socket |> commit(op) |> elem(1)}
    end

    def handle_event("resolve", %{"thread" => thread}, socket),
      do: {:noreply, socket |> commit(Ops.resolve(thread)) |> elem(1)}

    def handle_event("reopen", %{"thread" => thread}, socket),
      do: {:noreply, socket |> commit(Ops.reopen(thread)) |> elem(1)}

    defp commit(%{assigns: %{joined: false}} = socket, _op),
      do: {:error, assign(socket, :error, message(:not_joined))}

    defp commit(socket, op) do
      room = socket.assigns.room

      case Live.transact(room, Comments.document(room), [op]) do
        {:ok, _receipt} ->
          {:ok, assign(socket, error: nil, drafts: socket.assigns.drafts + 1)}

        {:error, reason} ->
          {:error, assign(socket, :error, message(reason))}
      end
    end

    defp message(:forbidden), do: "You may not comment here."
    defp message(:not_the_author), do: "Only its author changes a comment."
    defp message(:invalid_body), do: "A comment needs some words."
    defp message(:not_joined), do: "Comments come once the page is connected."
    defp message(_reason), do: "The comment could not be saved."

    # What a composer's form says: its words, and whom they mention. An
    # app's own input (the :input slot) says it with `read`, whose mentions
    # are its own (a Kotoba editor's, whose labels are the app's).
    defp read(%{assigns: %{read: read}}, params) when is_function(read, 1) do
      %{body: body} = said = read.(params)

      %{
        body: body,
        mentions: said |> Map.get(:mentions, []) |> Enum.map(&to_string/1) |> Enum.uniq()
      }
    end

    defp read(socket, params) do
      body = params["body"] || ""
      picked = (params["mentions"] || "") |> String.split(",", trim: true)
      %{body: body, mentions: mentions(socket, body, picked)}
    end

    # Whom a body mentions: those picked from the @ (whose "@Name" is still
    # in it), and an @ and the name of someone the panel offers, typed.
    defp mentions(socket, body, picked) do
      names = Map.new(socket.assigns.candidates, &{&1["key"], &1["name"]})

      chosen =
        for key <- picked, name = names[key], String.contains?(body, "@" <> name), do: key

      typed =
        socket.assigns.candidates
        |> Enum.sort_by(&(-String.length(&1["name"])))
        |> Enum.reduce({body, []}, fn %{"key" => key, "name" => name}, {rest, keys} ->
          if String.contains?(rest, "@" <> name),
            do: {String.replace(rest, "@" <> name, ""), keys ++ [key]},
            else: {rest, keys}
        end)
        |> elem(1)

      Enum.uniq(chosen ++ typed)
    end

    # Whom the @ offers: the people of the room, and `mentionable`, once each.
    defp candidates(%{assigns: %{joined: false}} = socket), do: given(socket)

    defp candidates(socket) do
      present =
        for {key, %{metas: [meta | _]}} <- Live.people(socket.assigns.room),
            is_binary(meta["name"]),
            do: %{
              "key" => key,
              "name" => meta["name"],
              "kind" => meta["kind"],
              "color" => meta["color"],
              "palette" => meta["palette"],
              "here" => true
            }

      Enum.uniq_by(present ++ given(socket), & &1["key"])
    end

    defp given(socket) do
      for person <- socket.assigns.mentionable,
          key = person[:key] || person["key"],
          name = person[:name] || person["name"] do
        key = to_string(key)

        %{
          "key" => key,
          "name" => to_string(name),
          "kind" => to_string(person[:kind] || person["kind"] || "human"),
          "color" => nil,
          "palette" => Color.index(key),
          "here" => false
        }
      end
    end

    @impl true
    def render(assigns) do
      visible = Enum.filter(assigns.threads, &(&1["status"] == assigns.status))
      counts = Enum.frequencies_by(assigns.threads, & &1["status"])

      assigns =
        assign(assigns,
          visible: visible,
          open_count: Map.get(counts, "open", 0),
          resolved_count: Map.get(counts, "resolved", 0),
          marked: marked(assigns.threads),
          reactions: @reactions
        )

      ~H"""
      <section
        id={@id}
        class={["issho-comments", @class]}
        phx-hook="IsshoComments"
        data-threads={JSON.encode!(@marked)}
        data-focused={@focused}
        data-marks={to_string(@marks)}
        data-mentionable={JSON.encode!(@candidates)}
        aria-labelledby={"#{@id}-title"}
      >
        <header class="issho-comments-header">
          <h2 id={"#{@id}-title"} class="issho-comments-title">Comments</h2>
          <div class="issho-segmented" role="group" aria-label="Show">
            <button
              type="button"
              phx-click="status"
              phx-value-status="open"
              phx-target={@myself}
              aria-pressed={to_string(@status == "open")}
            >
              Open <span class="issho-count">{@open_count}</span>
            </button>
            <button
              type="button"
              phx-click="status"
              phx-value-status="resolved"
              phx-target={@myself}
              aria-pressed={to_string(@status == "resolved")}
            >
              Resolved <span class="issho-count">{@resolved_count}</span>
            </button>
          </div>
        </header>

        <p :if={!@joined} class="issho-comments-note">Comments come once the page is connected.</p>

        <form
          :if={@joined}
          id={"#{@id}-new-#{@drafts}"}
          class="issho-composer"
          phx-submit="start"
          phx-target={@myself}
        >
          <label for={"#{@id}-new-body-#{@drafts}"} class="issho-visually-hidden">New comment</label>
          <.composer_input
            slot={@input}
            id={"#{@id}-new-body-#{@drafts}"}
            form={"#{@id}-new-#{@drafts}"}
            rows="2"
            placeholder="Add a comment… @ to mention"
          />
          <div class="issho-composer-bar">
            <fieldset :if={@selection} class="issho-composer-where">
              <legend class="issho-visually-hidden">Comment on</legend>
              <label class="issho-where">
                <input type="radio" name="where" value="selection" checked />
                <Issho.Icons.icon name="map-pin" />
                <span class="issho-where-label">
                  <.place_label slot={@place} place={@selection} default="Your selection" />
                </span>
              </label>
              <label class="issho-where">
                <input type="radio" name="where" value="page" />
                <Issho.Icons.icon name="file-text" /> Page
              </label>
            </fieldset>
            <input :if={!@selection} type="hidden" name="where" value="page" />
            <button type="submit" class="issho-button issho-button-primary">Comment</button>
          </div>
        </form>

        <p :if={@error} class="issho-comments-error" role="alert">{@error}</p>

        <ol
          :if={@visible != []}
          class="issho-threads"
          aria-label={if @status == "open", do: "Open threads", else: "Resolved threads"}
        >
          <li
            :for={thread <- @visible}
            class="issho-thread"
            data-thread={thread["id"]}
            data-status={thread["status"]}
            data-focused={thread["id"] == @focused}
            aria-current={if thread["id"] == @focused, do: "true"}
          >
            <div class="issho-thread-head">
              <button
                type="button"
                class="issho-thread-place"
                phx-click={if thread["id"] == @focused, do: "unfocus", else: "focus"}
                phx-value-thread={thread["id"]}
                phx-target={@myself}
                aria-expanded={to_string(thread["id"] == @focused)}
              >
                <Issho.Icons.icon name={if thread["place"], do: "map-pin", else: "file-text"} />
                <span class="issho-thread-place-label">
                  <.place_label
                    slot={@place}
                    place={thread["place"]}
                    default={if thread["place"], do: "On a part of the page", else: "On the page"}
                  />
                </span>
              </button>
              <button
                :if={@joined and thread["status"] == "open"}
                type="button"
                class="issho-icon-button issho-resolve"
                phx-click="resolve"
                phx-value-thread={thread["id"]}
                phx-target={@myself}
                aria-label="Resolve thread"
                title="Resolve"
              >
                <Issho.Icons.icon name="check" />
              </button>
              <button
                :if={@joined and thread["status"] == "resolved"}
                type="button"
                class="issho-icon-button"
                phx-click="reopen"
                phx-value-thread={thread["id"]}
                phx-target={@myself}
                aria-label="Reopen thread"
                title="Reopen"
              >
                <Issho.Icons.icon name="rotate-ccw" />
              </button>
            </div>

            <article
              :for={comment <- shown(thread, @focused)}
              class="issho-comment"
              data-kind={comment["author"]["kind"]}
            >
              <span
                class="issho-comment-avatar"
                style={"--issho-color: #{color(comment["author"])}"}
                aria-hidden="true"
              >
                {initials(comment["author"]["name"] || comment["author"]["key"])}
              </span>
              <div class="issho-comment-main">
                <header class="issho-comment-header">
                  <span class="issho-comment-author">
                    {comment["author"]["name"] || comment["author"]["key"]}
                  </span>
                  <span :if={comment["author"]["on_behalf_of"]} class="issho-comment-meta">
                    for {comment["author"]["on_behalf_of"]["name"] ||
                      comment["author"]["on_behalf_of"]["key"]}
                  </span>
                  <time datetime={comment["at"]} class="issho-comment-meta">{utc(comment["at"])}</time>
                  <span :if={comment["edited"]} class="issho-comment-meta">· edited</span>
                </header>

                <form
                  :if={@editing == {thread["id"], comment["id"]}}
                  id={"#{@id}-edit-#{comment["id"]}"}
                  class="issho-composer"
                  phx-submit="save"
                  phx-target={@myself}
                >
                  <input type="hidden" name="thread" value={thread["id"]} />
                  <input type="hidden" name="comment" value={comment["id"]} />
                  <label for={"#{@id}-edit-body-#{comment["id"]}"} class="issho-visually-hidden">
                    Edit comment
                  </label>
                  <.composer_input
                    slot={@input}
                    id={"#{@id}-edit-body-#{comment["id"]}"}
                    form={"#{@id}-edit-#{comment["id"]}"}
                    rows="2"
                    value={comment["body"]}
                  />
                  <div class="issho-composer-bar">
                    <button type="button" class="issho-button" phx-click="cancel" phx-target={@myself}>
                      Cancel
                    </button>
                    <button type="submit" class="issho-button issho-button-primary">Save</button>
                  </div>
                </form>

                <p :if={@editing != {thread["id"], comment["id"]}} class="issho-comment-body"><.body
                    body={comment["body"]}
                    names={mention_names(comment, @threads, @candidates)}
                  /></p>

                <div :if={comment["reactions"] != %{}} class="issho-reactions">
                  <button
                    :for={{emoji, keys} <- comment["reactions"]}
                    type="button"
                    class="issho-reaction"
                    phx-click="react"
                    phx-value-thread={thread["id"]}
                    phx-value-comment={comment["id"]}
                    phx-value-emoji={emoji}
                    phx-target={@myself}
                    aria-pressed={to_string(@me != nil and @me.key in keys)}
                    aria-label={"#{emoji} #{length(keys)}, #{if @me != nil and @me.key in keys, do: "take yours back", else: "add yours"}"}
                  >
                    <span aria-hidden="true">{emoji}</span>
                    <span class="issho-count">{length(keys)}</span>
                  </button>
                </div>
              </div>

              <div :if={@joined} class="issho-comment-tools" role="group" aria-label="Comment actions">
                <button
                  :for={emoji <- @reactions}
                  type="button"
                  class="issho-icon-button issho-react"
                  phx-click="react"
                  phx-value-thread={thread["id"]}
                  phx-value-comment={comment["id"]}
                  phx-value-emoji={emoji}
                  phx-target={@myself}
                  aria-label={"React with #{emoji}"}
                  title={"React with #{emoji}"}
                >
                  {emoji}
                </button>
                <span :if={@me != nil and comment["author"]["key"] == @me.key} class="issho-tools-own">
                  <button
                    type="button"
                    class="issho-icon-button"
                    phx-click="edit"
                    phx-value-thread={thread["id"]}
                    phx-value-comment={comment["id"]}
                    phx-target={@myself}
                    aria-label="Edit comment"
                    title="Edit"
                  >
                    <Issho.Icons.icon name="pencil" />
                  </button>
                  <button
                    type="button"
                    class="issho-icon-button issho-danger"
                    phx-click="delete"
                    phx-value-thread={thread["id"]}
                    phx-value-comment={comment["id"]}
                    phx-target={@myself}
                    data-confirm="Delete this comment?"
                    aria-label="Delete comment"
                    title="Delete"
                  >
                    <Issho.Icons.icon name="trash" />
                  </button>
                </span>
              </div>
            </article>

            <button
              :if={thread["id"] != @focused and length(thread["comments"]) > 1}
              type="button"
              class="issho-thread-replies"
              phx-click="focus"
              phx-value-thread={thread["id"]}
              phx-target={@myself}
            >
              {replies(length(thread["comments"]) - 1)}
            </button>

            <form
              :if={@joined and thread["id"] == @focused and thread["status"] == "open"}
              id={"#{@id}-reply-#{thread["id"]}-#{@drafts}"}
              class="issho-composer issho-composer-reply"
              phx-submit="reply"
              phx-target={@myself}
            >
              <input type="hidden" name="thread" value={thread["id"]} />
              <label for={"#{@id}-reply-body-#{thread["id"]}-#{@drafts}"} class="issho-visually-hidden">
                Reply
              </label>
              <.composer_input
                slot={@input}
                id={"#{@id}-reply-body-#{thread["id"]}-#{@drafts}"}
                form={"#{@id}-reply-#{thread["id"]}-#{@drafts}"}
                rows="1"
                placeholder="Reply…"
              />
              <button
                type="submit"
                class="issho-icon-button issho-send"
                aria-label="Send reply"
                title="Send"
              >
                <Issho.Icons.icon name="arrow-up" />
              </button>
            </form>
          </li>
        </ol>

        <div :if={@visible == []} class="issho-comments-empty">
          <Issho.Icons.icon name="message-square" class="issho-comments-empty-icon" />
          <p class="issho-comments-empty-title">
            {if @status == "open", do: "No open comments.", else: "No resolved comments."}
          </p>
          <p :if={@status == "open" and @joined} class="issho-comments-empty-hint">
            Select something on the page to comment on it.
          </p>
        </div>
      </section>
      """
    end

    attr :body, :string, required: true
    attr :names, :list, required: true

    # A comment's words, its mentions marked.
    defp body(assigns) do
      assigns = assign(assigns, :parts, parts(assigns.body, assigns.names))

      ~H"""
      <%= for {kind, text} <- @parts do %><span :if={kind == :mention} class="issho-mention">{text}</span><%= if kind == :text do %>{text}<% end %><% end %>
      """
    end

    @doc false
    # A body in pieces: text, and the "@Name" of each name it mentions.
    def parts(body, []), do: [{:text, body}]

    def parts(body, names) do
      pattern =
        names
        |> Enum.sort_by(&(-String.length(&1)))
        |> Enum.map_join("|", &Regex.escape("@" <> &1))
        |> Regex.compile!("u")

      pattern
      |> Regex.split(body, include_captures: true, trim: true)
      |> Enum.map(
        &if(Regex.match?(pattern, &1) and String.starts_with?(&1, "@"),
          do: {:mention, &1},
          else: {:text, &1}
        )
      )
    end

    # The names of the people a comment mentions, as the room's comments
    # know them (an author of one) or the @ offers them.
    defp mention_names(%{"mentions" => []}, _threads, _candidates), do: []

    defp mention_names(%{"mentions" => keys}, threads, candidates) do
      known =
        Map.merge(
          Map.new(candidates, &{&1["key"], &1["name"]}),
          for(
            thread <- threads,
            comment <- thread["comments"],
            into: %{},
            do: {comment["author"]["key"], comment["author"]["name"]}
          )
        )

      for key <- keys, name = known[key], is_binary(name), do: name
    end

    # The threads the page marks: those open, with a place.
    defp marked(threads) do
      for %{"status" => "open", "place" => %{"doc" => _} = place} = thread <- threads do
        [first | _] = thread["comments"]
        author = first["author"]
        count = length(thread["comments"])

        %{
          "id" => thread["id"],
          "place" => place,
          "count" => count,
          "label" =>
            "#{replies_label(count)}, #{author["name"] || author["key"]}: #{excerpt(first["body"])}",
          "color" => author["color"],
          "palette" => Color.index(author["key"])
        }
      end
    end

    defp shown(thread, focused) do
      if thread["id"] == focused, do: thread["comments"], else: Enum.take(thread["comments"], 1)
    end

    attr :slot, :list, required: true
    attr :id, :string, required: true
    attr :form, :string, required: true
    attr :rows, :string, required: true
    attr :value, :string, default: nil
    attr :placeholder, :string, default: nil

    # A composer's words: Issho's text area with its @ picker, or the app's
    # own input (the :input slot), and the field of the mentions picked,
    # which a render leaves as the picker set it.
    defp composer_input(%{slot: []} = assigns) do
      ~H"""
      <textarea
        id={@id}
        class="issho-composer-input"
        name="body"
        rows={@rows}
        required
        placeholder={@placeholder}
        data-issho-mentions
      >{@value}</textarea>
      <input type="hidden" id={"#{@form}-mentions"} name="mentions" value="" phx-update="ignore" />
      """
    end

    defp composer_input(assigns) do
      ~H"""
      {render_slot(@slot, %{
        id: @id,
        name: "body",
        value: @value,
        placeholder: @placeholder,
        field: Phoenix.Component.to_form(%{"body" => @value}, id: @id)[:body]
      })}
      """
    end

    attr :slot, :list, required: true
    attr :place, :map, default: nil
    attr :default, :string, required: true

    # A thread's place in words: the app's, from the :place slot, or the default.
    defp place_label(%{slot: []} = assigns), do: ~H"{@default}"
    defp place_label(assigns), do: ~H"{render_slot(@slot, %{place: @place, default: @default})}"

    defp find(list, id), do: Enum.find(list, &(&1["id"] == id))

    defp replies(1), do: "1 reply"
    defp replies(n), do: "#{n} replies"

    defp replies_label(1), do: "1 comment"
    defp replies_label(n), do: "#{n} comments"

    defp excerpt(body) do
      if String.length(body) > 80, do: String.slice(body, 0, 79) <> "…", else: body
    end

    defp color(author),
      do: author["color"] || "var(--issho-person-#{Color.index(author["key"])})"

    defp initials(name) do
      name
      |> String.split(~r/[\s:_-]+/u, trim: true)
      |> Enum.take(2)
      |> Enum.map_join(&String.first/1)
      |> String.upcase()
    end

    defp utc(at) do
      case DateTime.from_iso8601(at) do
        {:ok, time, _} -> Calendar.strftime(time, "%b %-d, %H:%M UTC")
        _ -> at
      end
    end
  end
end
