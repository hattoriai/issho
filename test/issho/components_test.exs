defmodule Issho.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Issho.Components

  defp meta(name, extra),
    do:
      Map.merge(
        %{"name" => name, "kind" => "human", "can" => "write", "joined_at" => 1, "palette" => 3},
        extra
      )

  test "the server renders each person once, the agents with whom they act for, the viewers as viewers" do
    people = %{
      "user:ada" => %{metas: [meta("Ada Lovelace", %{"color" => "#2563eb"})]},
      "agent:claude" => %{
        metas: [
          meta("Claude Code", %{
            "kind" => "agent",
            "joined_at" => 2,
            "on_behalf_of" => %{"name" => "Ada"}
          })
        ]
      },
      "user:ken" => %{
        metas: [
          meta("Ken", %{"can" => "read", "joined_at" => 3}),
          meta("Ken", %{"can" => "read"})
        ]
      },
      "bot:app" => %{metas: [meta("Bot", %{"kind" => "service", "joined_at" => 4})]}
    }

    assigns = %{people: people}

    html =
      rendered_to_string(~H"""
      <Components.people id="people" people={@people} self="user:ken" max={3} />
      """)

    doc = LazyHTML.from_fragment(html)
    items = LazyHTML.query(doc, "li.issho-person")
    labels = doc |> LazyHTML.query(".issho-person-label") |> Enum.map(&LazyHTML.text/1)

    assert labels == ["Ken (you), viewing", "Ada Lovelace", "Claude Code, an agent for Ada"]
    assert html =~ "--issho-color: #2563eb"
    assert html =~ "--issho-color: var(--issho-person-3)"
    assert doc |> LazyHTML.query(".issho-badge") |> LazyHTML.text() |> String.trim() == "AI"

    assert doc
           |> LazyHTML.query(".issho-avatar")
           |> Enum.map(&LazyHTML.text/1)
           |> Enum.map(&String.trim/1) == ["KE", "AL", "CC"]

    assert Enum.count(items) == 4
    assert doc |> LazyHTML.query(".issho-person-more") |> LazyHTML.text() |> String.trim() == "+1"
  end

  test "an app draws a person with its own markup, and Issho keeps the item and its label" do
    assigns = %{people: %{"user:ada" => %{metas: [meta("Ada Lovelace", %{})]}}}

    html =
      rendered_to_string(~H"""
      <Components.people id="people" people={@people}>
        <:person :let={one}><b class="mine">{one.name}</b></:person>
      </Components.people>
      """)

    doc = LazyHTML.from_fragment(html)
    assert doc |> LazyHTML.query("li.issho-person .mine") |> LazyHTML.text() == "Ada Lovelace"
    assert doc |> LazyHTML.query(".issho-avatar") |> Enum.count() == 0
    assert doc |> LazyHTML.query(".issho-person-label") |> LazyHTML.text() == "Ada Lovelace"
  end

  test "with a grant, the browser draws them" do
    assigns = %{grant: %{"room" => "board:1", "token" => "t", "self" => "user:ada"}}

    html =
      rendered_to_string(~H"""
      <Components.people id="people" grant={@grant} />
      """)

    assert html =~ ~s(phx-hook="IsshoPeople")
    assert html =~ "board:1"
  end
end
