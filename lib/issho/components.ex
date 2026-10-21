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

    ## The page as a live space

    Each person's pointer over the page, and their clicks, in their
    colour, with their name, over any part of the page: Issho's components
    and plain HEEx alike (the `IsshoPointers` hook):

        <Issho.Components.pointers id="pointers" grant={@grant} />

    A pointer is a point of an element, not of the screen, so each person
    sees it on the same part of their own page, whatever its size and
    scroll: the nearest element with `data-issho-anchor`, else with an
    id. Off the screen, it is a marker at its edge that scrolls to it.
    Inside an element with `data-issho-cursor="own"` (a canvas that draws
    its people itself) the component takes over. Over an element with
    `data-issho-private`, or a password field, the browser shares nothing,
    nor while its window is in the background. An agent at work in a
    document is drawn at its component, the element with
    `data-issho-doc` of the document's id. `share={false}` shows the others
    without sharing this person's pointer.
    """

    use Phoenix.Component

    attr :id, :string, required: true
    attr :grant, :map, required: true, doc: "a grant of the room, from `Issho.Live.grant/4`"
    attr :share, :boolean, default: true, doc: "whether this person's pointer is shared"
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
    attr :class, :string, default: nil
    attr :rest, :global

    def people(%{grant: %{"room" => _}} = assigns) do
      ~H"""
      <div
        id={@id}
        class={["issho-people-of", @class]}
        phx-hook="IsshoPeople"
        phx-update="ignore"
        data-grant={JSON.encode!(@grant)}
        data-max={@max}
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
            <span class="issho-avatar" aria-hidden="true">
              <img :if={one.avatar} src={one.avatar} alt="" />
              <%= if !one.avatar do %>{one.initials}<% end %>
            </span>
            <span :if={one.kind != "human"} class="issho-badge" aria-hidden="true">
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
  end
end
