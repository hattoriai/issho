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

    def update(%{issho: _other}, socket), do: {:ok, socket}

    def update(assigns, socket) do
      socket =
        socket
        |> assign(Map.drop(assigns, [:flash]))
        |> assign_new(:mentionable, fn -> [] end)
        |> assign_new(:marks, fn -> true end)
        |> assign_new(:place, fn -> [] end)
        |> assign_new(:class, fn -> nil end)

      {:ok, if(socket.assigns.joined, do: socket, else: open(socket))}
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

    def handle_event("start", %{"body" => body} = params, socket) do
      place = if params["where"] == "selection", do: socket.assigns.selection
      {op, ids} = Ops.start(socket.assigns.me, place, body, mentions: mentions(socket, body))

      case commit(socket, op) do
        {:ok, socket} -> {:noreply, assign(socket, focused: ids.thread, status: "open")}
        {:error, socket} -> {:noreply, socket}
      end
    end

    def handle_event("reply", %{"thread" => thread, "body" => body}, socket) do
      {op, _ids} = Ops.reply(socket.assigns.me, thread, body, mentions: mentions(socket, body))
      {:noreply, socket |> commit(op) |> elem(1)}
    end

    def handle_event("edit", %{"thread" => thread, "comment" => comment}, socket),
      do: {:noreply, assign(socket, editing: {thread, comment}, focused: thread)}

    def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, editing: nil)}

    def handle_event("save", %{"thread" => thread, "comment" => comment, "body" => body}, socket) do
      op = Ops.edit(thread, comment, body, mentions: mentions(socket, body))

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

    # The people a body mentions: an @ and the name of someone of the room,
    # or of `mentionable`, the longest name first.
    defp mentions(socket, body) do
      socket
      |> names()
      |> Enum.sort_by(fn {_key, name} -> -String.length(name) end)
      |> Enum.reduce({body, []}, fn {key, name}, {rest, keys} ->
        if String.contains?(rest, "@" <> name),
          do: {String.replace(rest, "@" <> name, ""), keys ++ [key]},
          else: {rest, keys}
      end)
      |> elem(1)
      |> Enum.uniq()
    end

    defp names(socket) do
      present =
        for {key, %{metas: [meta | _]}} <- Live.people(socket.assigns.room),
            is_binary(meta["name"]),
            do: {key, meta["name"]}

      given =
        for person <- socket.assigns.mentionable,
            key = person[:key] || person["key"],
            name = person[:name] || person["name"],
            do: {to_string(key), to_string(name)}

      Enum.uniq_by(present ++ given, &elem(&1, 0))
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
          marked: marked(assigns.threads)
        )

      ~H"""
      <section
        id={@id}
        class={["issho-comments", @class]}
        phx-hook="IsshoComments"
        data-threads={JSON.encode!(@marked)}
        data-focused={@focused}
        data-marks={to_string(@marks)}
        aria-labelledby={"#{@id}-title"}
      >
        <header class="issho-comments-header">
          <h2 id={"#{@id}-title"} class="issho-comments-title">Comments</h2>
          <div class="issho-comments-status" role="group" aria-label="Show">
            <button
              type="button"
              phx-click="status"
              phx-value-status="open"
              phx-target={@myself}
              aria-pressed={to_string(@status == "open")}
            >
              Open <span class="issho-comments-count">{@open_count}</span>
            </button>
            <button
              type="button"
              phx-click="status"
              phx-value-status="resolved"
              phx-target={@myself}
              aria-pressed={to_string(@status == "resolved")}
            >
              Resolved <span class="issho-comments-count">{@resolved_count}</span>
            </button>
          </div>
        </header>

        <p :if={!@joined} class="issho-comments-note">Comments come once the page is connected.</p>

        <form
          :if={@joined}
          id={"#{@id}-new-#{@drafts}"}
          class="issho-comment-composer"
          phx-submit="start"
          phx-target={@myself}
        >
          <label for={"#{@id}-new-body-#{@drafts}"} class="issho-comments-label">New comment</label>
          <textarea
            id={"#{@id}-new-body-#{@drafts}"}
            name="body"
            rows="2"
            required
            placeholder="Add a comment. @ a name to mention someone."
          ></textarea>
          <fieldset :if={@selection} class="issho-comment-where">
            <legend class="issho-comments-label">On</legend>
            <label>
              <input type="radio" name="where" value="selection" checked /> <.place_label slot={@place} place={@selection} default="your selection" />
            </label>
            <label><input type="radio" name="where" value="page" /> the page</label>
          </fieldset>
          <input :if={!@selection} type="hidden" name="where" value="page" />
          <button type="submit" class="issho-comment-send">Comment</button>
        </form>

        <p :if={@error} class="issho-comments-error" role="alert">{@error}</p>

        <ol class="issho-threads" aria-label={if @status == "open", do: "Open threads", else: "Resolved threads"}>
          <li
            :for={thread <- @visible}
            class="issho-thread"
            data-thread={thread["id"]}
            data-focused={thread["id"] == @focused}
            aria-current={if thread["id"] == @focused, do: "true"}
          >
            <button
              type="button"
              class="issho-thread-place"
              phx-click={if thread["id"] == @focused, do: "unfocus", else: "focus"}
              phx-value-thread={thread["id"]}
              phx-target={@myself}
              aria-expanded={to_string(thread["id"] == @focused)}
            >
              <.place_label
                slot={@place}
                place={thread["place"]}
                default={if thread["place"], do: "On a part of the page", else: "On the page"}
              />
            </button>

            <article
              :for={comment <- shown(thread, @focused)}
              class="issho-comment"
              data-kind={comment["author"]["kind"]}
            >
              <header class="issho-comment-header">
                <span
                  class="issho-comment-avatar"
                  style={"--issho-color: #{color(comment["author"])}"}
                  aria-hidden="true"
                >
                  {initials(comment["author"]["name"] || comment["author"]["key"])}
                </span>
                <span class="issho-comment-author">{comment["author"]["name"] || comment["author"]["key"]}</span>
                <span :if={comment["author"]["on_behalf_of"]} class="issho-comment-behalf">
                  for {comment["author"]["on_behalf_of"]["name"] ||
                    comment["author"]["on_behalf_of"]["key"]}
                </span>
                <time datetime={comment["at"]} class="issho-comment-time">{utc(comment["at"])}</time>
                <span :if={comment["edited"]} class="issho-comment-edited">(edited)</span>
              </header>

              <form
                :if={@editing == {thread["id"], comment["id"]}}
                id={"#{@id}-edit-#{comment["id"]}"}
                class="issho-comment-composer"
                phx-submit="save"
                phx-target={@myself}
              >
                <input type="hidden" name="thread" value={thread["id"]} />
                <input type="hidden" name="comment" value={comment["id"]} />
                <label for={"#{@id}-edit-body-#{comment["id"]}"} class="issho-comments-label">Edit comment</label>
                <textarea id={"#{@id}-edit-body-#{comment["id"]}"} name="body" rows="2" required>{comment["body"]}</textarea>
                <button type="submit" class="issho-comment-send">Save</button>
                <button type="button" phx-click="cancel" phx-target={@myself}>Cancel</button>
              </form>

              <p :if={@editing != {thread["id"], comment["id"]}} class="issho-comment-body"><.body body={comment["body"]} names={mention_names(comment, @threads)} /></p>

              <footer class="issho-comment-footer">
                <button
                  :for={emoji <- emojis(comment)}
                  type="button"
                  class="issho-reaction"
                  phx-click="react"
                  phx-value-thread={thread["id"]}
                  phx-value-comment={comment["id"]}
                  phx-value-emoji={emoji}
                  phx-target={@myself}
                  aria-pressed={to_string(@me != nil and @me.key in Map.get(comment["reactions"], emoji, []))}
                  aria-label={"React with #{emoji}, #{length(Map.get(comment["reactions"], emoji, []))}"}
                >
                  {emoji} <span :if={Map.get(comment["reactions"], emoji, []) != []}>{length(comment["reactions"][emoji])}</span>
                </button>
                <span :if={@me != nil and comment["author"]["key"] == @me.key} class="issho-comment-own">
                  <button
                    type="button"
                    phx-click="edit"
                    phx-value-thread={thread["id"]}
                    phx-value-comment={comment["id"]}
                    phx-target={@myself}
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-thread={thread["id"]}
                    phx-value-comment={comment["id"]}
                    phx-target={@myself}
                    data-confirm="Delete this comment?"
                  >
                    Delete
                  </button>
                </span>
              </footer>
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
              :if={@joined and thread["id"] == @focused}
              id={"#{@id}-reply-#{thread["id"]}-#{@drafts}"}
              class="issho-comment-composer"
              phx-submit="reply"
              phx-target={@myself}
            >
              <input type="hidden" name="thread" value={thread["id"]} />
              <label for={"#{@id}-reply-body-#{thread["id"]}-#{@drafts}"} class="issho-comments-label">Reply</label>
              <textarea id={"#{@id}-reply-body-#{thread["id"]}-#{@drafts}"} name="body" rows="2" required placeholder="Reply"></textarea>
              <button type="submit" class="issho-comment-send">Reply</button>
            </form>

            <div :if={@joined} class="issho-thread-actions">
              <button
                :if={thread["status"] == "open"}
                type="button"
                phx-click="resolve"
                phx-value-thread={thread["id"]}
                phx-target={@myself}
              >
                Resolve
              </button>
              <button
                :if={thread["status"] == "resolved"}
                type="button"
                phx-click="reopen"
                phx-value-thread={thread["id"]}
                phx-target={@myself}
              >
                Reopen
              </button>
            </div>
          </li>
        </ol>

        <p :if={@visible == []} class="issho-comments-empty">
          {if @status == "open", do: "No open comments.", else: "No resolved comments."}
        </p>
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
    # know them (an author of one), else as they are mentioned.
    defp mention_names(%{"mentions" => []}, _threads), do: []

    defp mention_names(%{"mentions" => keys}, threads) do
      authors =
        for thread <- threads,
            comment <- thread["comments"],
            into: %{},
            do: {comment["author"]["key"], comment["author"]["name"]}

      for key <- keys, name = authors[key], is_binary(name), do: name
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
    attr :place, :map, default: nil
    attr :default, :string, required: true

    # A thread's place in words: the app's, from the :place slot, or the default.
    defp place_label(%{slot: []} = assigns), do: ~H"{@default}"
    defp place_label(assigns), do: ~H"{render_slot(@slot, %{place: @place, default: @default})}"

    defp emojis(comment), do: Enum.uniq(@reactions ++ Map.keys(comment["reactions"]))

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
