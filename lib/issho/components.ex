if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Issho.Components do
    @moduledoc ~S"""
    Issho's pieces of a page, in HEEx. Style them with Issho's theme:
    `issho.css`, and `issho-sumi.css` after it for the Sumi theme (in the
    package's `priv/static`).

    ## The people of a room

    One list for the page, whatever its components (editors, grids, a
    canvas): each person and agent once, in their colour, the agents with
    whom they act for, the viewers as viewers, and what each says they are
    doing.

    With a grant (`Issho.Live.grant/4`), the browser keeps it live (the
    `IsshoPeople` hook of `Hooks` from `issho`, in your LiveSocket):

        <Issho.Components.people id="people" grant={@grant} />

    In a LiveView that is in the room itself (`Issho.Live.join/4`), the
    server renders it, from `Issho.Live.people/1`:

        <Issho.Components.people id="people" people={Issho.Live.people(@room)} self={@me} />

    ## The look

    Issho's theme (`issho.css`) styles every piece through custom
    properties: the avatars' size, shape, edge and initials, the badges,
    the pointers' names (`--issho-avatar-radius`, `--issho-avatar-text`,
    `--issho-pointer-radius`... see the file), and the palette of the
    people with no colour of their own (`--issho-person-1` to `-8`). Set
    them in your CSS to match your app. The classes and data attributes
    are stable: leave the file out to style them all yourself. And draw a
    person or a pointer with your own markup: the `:person` slot of a list
    the server renders, or `configure({person, pointer})` of the `issho`
    package for the live list and the pointers.

    ## The page as a live space

    Each person's pointer over the page, and their clicks, in their
    colour, with their name, over any part of the page: Issho's components
    and plain HEEx alike (the `IsshoPointers` hook):

        <Issho.Components.pointers id="pointers" grant={@grant} />

    A pointer is a point of an element, not of the screen, so each person
    sees it on the same part of their own page, whatever its size and
    scroll: the nearest element with `data-issho-anchor`, else with an
    id. Over a component that says what is under a point (`point` in the
    `issho` package: a canvas's point, a grid's cell), it is a place of
    the component's document, drawn where that place is on each screen
    (`locate`): the same cell in another order, the same point of a
    canvas panned elsewhere. So one pointer goes from block to block of
    the page, and into a block within a block. Off the screen, it is a
    marker at its edge that scrolls to it. Inside an element with
    `data-issho-cursor="own"` (a component that draws its people itself,
    and says nothing of its points) the component takes over. Over an
    element with `data-issho-private`, or a password field, the browser
    shares nothing, nor while its window is in the background.
    `share={false}` shows the others without sharing this person's
    pointer.

    ## Agents moving

    An agent goes where it works as a hand would (`Issho.Motion`): its
    pointer glides there, in the time the agent says, to a place of a
    document (its caret, a node, a cell) or an element of the page
    (`data-issho-anchor`), and rings where it clicks. The pointers tell
    the room what each browser shows (the page in the foreground, the
    components on the screen, whether its person wants motion), so that an
    agent moves only for someone who sees it.

    How much a person wants to see others move is the app's to say, from
    its own settings: `motion="reduced"` on the pointers, `setMotion` of
    the `issho` package, or `data-issho-motion` on the page's root
    element; else the browser's "reduce motion" setting. `motion_switch/1`
    is a switch for it, to place and style as you like, or not at all.

    ## Following

    A click on someone in the people list follows them (`follow={false}`
    for a list that does not): on a page whose blocks share the room,
    each block shows where they are (the grid their view, the canvas their
    viewport, the text their caret) and the page scrolls to them. A link
    or a button with `data-issho-follow` that they click is clicked for
    those who follow them too: the agent clicks "Edit together", and its
    person, following it, is in the editor. Going one's own way (a scroll,
    a click, a key) stops following. A block alone in its room follows
    within itself, by the same contract (`follow` of the `issho` package,
    or the `issho:following` event and `data-issho-following` on the
    page's root element for a block's own script).
    """

    use Phoenix.Component

    attr :id, :string, required: true
    attr :grant, :map, required: true, doc: "a grant of the room, from `Issho.Live.grant/4`"
    attr :share, :boolean, default: true, doc: "whether this person's pointer is shared"

    attr :motion, :string,
      default: nil,
      values: [nil, "full", "reduced"],
      doc:
        "how much this person wants to see others move, from the app's settings; the browser's setting unless given"

    attr :class, :string, default: nil
    attr :rest, :global

    @doc "The pointers of the room's people over the page: a layer over the viewport."
    def pointers(assigns) do
      ~H"""
      <div
        id={@id}
        class={["issho-pointers", @class]}
        phx-hook="IsshoPointers"
        phx-update="ignore"
        data-grant={JSON.encode!(@grant)}
        data-share={to_string(@share)}
        data-motion={@motion}
        {@rest}
      >
      </div>
      """
    end

    attr :id, :string, required: true
    attr :grant, :map, default: nil, doc: "a grant of the room, from `Issho.Live.grant/4`"

    attr :people, :map,
      default: nil,
      doc: "the room's people, from `Issho.Live.people/1` (without a grant)"

    attr :self, :string, default: nil, doc: "this actor's key, with `people`"
    attr :max, :integer, default: 8, doc: "how many avatars before \"+N\""
    attr :label, :string, default: "People here"

    attr :follow, :boolean,
      default: true,
      doc: "with a grant: whether a click on someone follows them"

    attr :class, :string, default: nil
    attr :rest, :global

    slot :person,
      doc:
        "with `people`: draws a person in place of the avatar (`:let`: `key`, `name`, `avatar`, `initials`, `color`, `kind`, `you`); with a grant, the browser draws them: `configure({person})` of the `issho` package"

    def people(%{grant: %{"room" => _}} = assigns) do
      ~H"""
      <div
        id={@id}
        class={["issho-people-of", @class]}
        phx-hook="IsshoPeople"
        phx-update="ignore"
        data-grant={JSON.encode!(@grant)}
        data-max={@max}
        data-label={@label}
        data-follow={to_string(@follow)}
        {@rest}
      >
        <ul class="issho-people" aria-label={@label}></ul>
      </div>
      """
    end

    def people(%{people: people} = assigns) when is_map(people) do
      everyone =
        people
        |> Enum.map(fn {key, %{metas: metas}} -> person(key, metas, assigns.self) end)
        |> Enum.sort_by(&{not &1.you, &1.joined_at})

      assigns =
        assign(assigns,
          shown: Enum.take(everyone, assigns.max),
          hidden: Enum.drop(everyone, assigns.max)
        )

      ~H"""
      <div id={@id} class={["issho-people-of", @class]} {@rest}>
        <ul class="issho-people" aria-label={@label}>
          <li
            :for={one <- @shown}
            class="issho-person"
            data-kind={one.kind}
            data-key={one.key}
            data-viewing={one.can == "read"}
            data-you={one.you}
            style={"--issho-color: #{one.color}"}
            title={one.description}
          >
            <%= if @person != [] do %>
              <span class="issho-person-own" aria-hidden="true">{render_slot(@person, one)}</span>
            <% else %>
              <span class="issho-avatar" aria-hidden="true">
                <img :if={one.avatar} src={one.avatar} alt="" />
                <%= if !one.avatar do %>{one.initials}<% end %>
              </span>
            <% end %>
            <span :if={one.kind != "human" and @person == []} class="issho-badge" aria-hidden="true">
              {if one.kind == "agent", do: "AI", else: "App"}
            </span>
            <span class="issho-person-label">{one.description}</span>
          </li>
          <li :if={@hidden != []} class="issho-person issho-person-more" title={Enum.map_join(@hidden, "\n", & &1.description)}>
            +{length(@hidden)}
          </li>
        </ul>
      </div>
      """
    end

    # A person from their tabs' metas, as the browser's list makes one.
    defp person(key, metas, self) do
      first = Enum.min_by(metas, &(&1["joined_at"] || 0))
      can = if Enum.any?(metas, &(&1["can"] == "write")), do: "write", else: "read"
      name = first["name"] || key
      kind = to_string(first["kind"] || "human")

      %{
        key: key,
        name: name,
        kind: kind,
        can: can,
        you: key == self,
        avatar: first["avatar"],
        joined_at: first["joined_at"] || 0,
        color:
          first["color"] || "var(--issho-person-#{first["palette"] || Issho.Color.index(key)})",
        initials: initials(name),
        description:
          describe(name, kind, can, key == self, get_in(first, ["on_behalf_of", "name"]))
      }
    end

    defp describe(name, kind, can, you, behalf) do
      [
        name,
        if(you, do: " (you)"),
        case {kind, behalf} do
          {"agent", nil} -> ", an agent"
          {"agent", behalf} -> ", an agent for #{behalf}"
          {"service", _} -> ", the app"
          _ -> nil
        end,
        if(can == "read", do: ", viewing")
      ]
      |> Enum.join()
    end

    defp initials(name) do
      words =
        name
        |> String.replace(~r/^[a-z]+:/i, "")
        |> String.split(~r/[\s._-]+/, trim: true)

      letters =
        case words do
          [] -> "?"
          [one] -> String.slice(one, 0, 2)
          [first | rest] -> String.first(first) <> String.first(List.last(rest))
        end

      String.upcase(letters)
    end

    attr :id, :string, required: true
    attr :label, :string, default: "Show others moving"

    attr :event, :string,
      default: nil,
      doc:
        "an event pushed to the LiveView with `%{\"motion\" => \"full\" | \"reduced\"}` when it changes, to keep it in the person's settings"

    attr :class, :string, default: nil
    attr :rest, :global

    @doc """
    A switch for how much this person wants to see others move: pressed,
    pointers glide, carets travel and selections sweep; not, they are
    there at once. Optional: place it where your settings are, style it
    (`.issho-motion-switch`, `aria-pressed`), or use your own control with
    `setMotion` of the `issho` package (the `IsshoMotion` hook).
    """
    def motion_switch(assigns) do
      ~H"""
      <button
        id={@id}
        type="button"
        class={["issho-motion-switch", @class]}
        phx-hook="IsshoMotion"
        aria-pressed="true"
        data-event={@event}
        {@rest}
      >
        {@label}
      </button>
      """
    end
  end
end
