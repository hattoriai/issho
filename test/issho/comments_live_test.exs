defmodule Issho.CommentsLiveTest do
  # The room's comments on a page: the panel, its composer and its
  # threads, from two people's LiveViews.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import IsshoTest.Sync

  alias Issho.{Comments, Participant, Transaction}

  @instance IsshoTest.Issho
  @endpoint IsshoTest.Endpoint

  setup do
    %{room: "board:" <> Transaction.id(), conn: build_conn()}
  end

  defp page(conn, room, user, extra \\ %{}) do
    session = Map.merge(%{"user" => user, "room" => room, "name" => name(user)}, extra)
    {:ok, view, _html} = live_isolated(conn, IsshoTest.CommentsLive, session: session)
    view
  end

  defp name("user:" <> name), do: String.capitalize(name)

  defp start(view, body, where \\ "page"),
    do:
      view
      |> element(~s(form[phx-submit="start"]))
      |> render_submit(%{"body" => body, "where" => where})

  defp settled(views), do: Enum.each(views, &settle(&1.pid))

  test "a thread on the page, a reply, a reaction, resolved", %{conn: conn, room: room} do
    ada = page(conn, room, "user:ada")
    ken = page(conn, room, "user:ken")

    start(ada, "Should this go first?")
    settled([ada, ken])

    assert render(ken) =~ "Should this go first?"
    assert ken |> element(".issho-thread-place") |> render() =~ "On the page"

    [thread] = threads(room)
    ken |> element(".issho-thread-place") |> render_click()

    ken
    |> element(~s(form[phx-submit="reply"]))
    |> render_submit(%{"thread" => thread["id"], "body" => "Yes."})

    settled([ada, ken])

    # Ada's thread is open in her panel, with its replies; elsewhere, a count.
    assert ada |> element(".issho-thread") |> render() =~ "Yes."
    ken |> element(~s(.issho-thread-place)) |> render_click()
    assert ken |> element(".issho-thread-replies") |> render() =~ "1 reply"

    ken |> element(~s(.issho-reaction[phx-value-emoji="👍"]), "👍") |> render_click()
    settled([ada, ken])

    assert ada
           |> element(~s(.issho-comment:first-of-type .issho-reaction[phx-value-emoji="👍"]))
           |> render() =~ "1"

    ada |> element(~s(button[phx-click="resolve"])) |> render_click()
    settled([ada, ken])

    assert render(ken) =~ "No open comments."
    ken |> element(~s(button[phx-value-status="resolved"])) |> render_click()
    assert render(ken) =~ "Should this go first?"
    assert ken |> element(~s(button[phx-click="reopen"])) |> has_element?()
  end

  test "only its author edits or deletes a comment", %{conn: conn, room: room} do
    ada = page(conn, room, "user:ada")
    ken = page(conn, room, "user:ken")
    start(ada, "Mine")
    settled([ada, ken])

    refute ken |> element(~s(button[phx-click="edit"])) |> has_element?()

    ada |> element(~s(button[phx-click="edit"])) |> render_click()
    [%{"id" => thread, "comments" => [%{"id" => comment}]}] = threads(room)

    ada
    |> element(~s(form[phx-submit="save"]))
    |> render_submit(%{"thread" => thread, "comment" => comment, "body" => "Mine, better"})

    settled([ada, ken])
    assert render(ken) =~ "Mine, better"
    assert render(ken) =~ "(edited)"

    ada |> element(~s(button[phx-click="delete"])) |> render_click()
    settled([ada, ken])
    assert render(ken) =~ "No open comments."
  end

  test "a comment on what the person selected", %{conn: conn, room: room} do
    ada = page(conn, room, "user:ada")

    # Ada's browser: a component's selection.
    {:ok, browser} = Issho.join_as(@instance, %{id: "user:ada", name: "Ada"}, room)
    place = %{"doc" => room, "at" => %{"path" => ["title", "words"]}}
    :ok = Participant.place(browser, place)

    # The next frame of the room's awareness reaches the panel.
    Process.sleep(60)
    settled([ada])
    assert ada |> element(".issho-comment-where") |> render() =~ "Path title.words"

    start(ada, "Too long?", "selection")
    settled([ada])

    assert [%{"place" => ^place}] = threads(room)
    assert ada |> element(".issho-thread-place") |> render() =~ "Path title.words"

    # The page marks it, at its place.
    assert [%{"place" => ^place, "count" => 1, "label" => "1 comment, Ada: Too long?"}] =
             ada |> element("#comments") |> render() |> marked()
  end

  test "an @ and a name mentions someone", %{conn: conn, room: room} do
    ada = page(conn, room, "user:ada")
    _ken = page(conn, room, "user:ken")

    start(ada, "@Ken and @Claude, a look?")
    assert [%{"comments" => [%{"mentions" => mentions}]}] = threads(room)
    assert Enum.sort(mentions) == ["agent:claude", "user:ken"]
  end

  test "a server's comment comes live", %{conn: conn, room: room} do
    ada = page(conn, room, "user:ada")

    {:ok, _} =
      Comments.start(
        @instance,
        room,
        %{id: "agent:claude", name: "Claude", kind: :agent},
        nil,
        "Done."
      )

    settled([ada])
    html = render(ada)
    assert html =~ "Done."
    assert html =~ ~s(data-kind="agent")
  end

  test "a reader comments when the policy allows it", %{conn: conn} do
    room = "readonly:" <> Transaction.id()
    reader = page(conn, room, "user:ken", %{"can" => :read})
    start(reader, "A question")
    settled([reader])
    assert render(reader) =~ "A question"
  end

  test "a refused comment says why", %{conn: conn, room: room} do
    ada = page(conn, room, "user:ada")
    IsshoTest.Policy.deny_action(:comment)
    on_exit(fn -> IsshoTest.Policy.allow_action(:comment) end)

    start(ada, "Hello")
    assert ada |> element(".issho-comments-error") |> render() =~ "You may not comment here."
  end

  test "before the page is connected", %{room: room} do
    html = render_component(Issho.Live.Comments, id: "comments", room: room)
    assert html =~ "Comments come once the page is connected."
    refute html =~ "issho-comment-composer"
  end

  test "a body's mentions, marked" do
    assert Issho.Live.Comments.parts("Hi @Ada and @Ada Lovelace!", ["Ada", "Ada Lovelace"]) == [
             {:text, "Hi "},
             {:mention, "@Ada"},
             {:text, " and "},
             {:mention, "@Ada Lovelace"},
             {:text, "!"}
           ]

    assert Issho.Live.Comments.parts("No one", []) == [{:text, "No one"}]
  end

  defp threads(room) do
    {:ok, threads} = Comments.threads(@instance, room)
    threads
  end

  defp marked(html) do
    [section] = html |> LazyHTML.from_fragment() |> LazyHTML.query("#comments") |> Enum.to_list()
    [threads] = LazyHTML.attribute(section, "data-threads")
    JSON.decode!(threads)
  end
end
