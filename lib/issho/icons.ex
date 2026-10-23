if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Issho.Icons do
    @moduledoc false
    # The icons of Issho's pieces of a page: Lucide icons
    # (https://lucide.dev, ISC licence), drawn with strokes of
    # `currentColor`, as Kotoba's toolbar and Hakushi's kits draw theirs.
    # The browser's half draws the same (assets/src/icons.ts).

    use Phoenix.Component

    @shapes %{
      "check" => ~s(<path d="M20 6 9 17l-5-5"/>),
      "rotate-ccw" =>
        ~s(<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>),
      "smile-plus" =>
        ~s(<path d="M22 11v1a10 10 0 1 1-9-10"/><path d="M8 14s1.5 2 4 2 4-2 4-2"/><line x1="9" x2="9.01" y1="9" y2="9"/><line x1="15" x2="15.01" y1="9" y2="9"/><path d="M16 5h6"/><path d="M19 2v6"/>),
      "pencil" =>
        ~s(<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/>),
      "trash" =>
        ~s(<path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/>),
      "map-pin" =>
        ~s(<path d="M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0"/><circle cx="12" cy="10" r="3"/>),
      "file-text" =>
        ~s(<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>),
      "message-square" =>
        ~s(<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>),
      "arrow-up" => ~s(<path d="m5 12 7-7 7 7"/><path d="M12 19V5"/>)
    }

    @doc false
    def names, do: Map.keys(@shapes)

    attr :name, :string, required: true
    attr :class, :string, default: "issho-icon"

    def icon(assigns) do
      assigns = assign(assigns, :shape, Map.fetch!(@shapes, assigns.name))

      ~H"""
      <svg
        class={@class}
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
        focusable="false"
      >
        {Phoenix.HTML.raw(@shape)}
      </svg>
      """
    end
  end
end
