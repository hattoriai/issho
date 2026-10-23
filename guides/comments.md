# Comments

People and agents talk about what is on the page where it is: a thread on
a range of a text, a node of a canvas, a cell of a grid, or the page as a
whole. `Issho.Comments` gives every component of a room the same threads,
without a table of your own: replies, edits and deletes by their authors,
reactions, @mentions of people and agents, resolve and reopen, shared live
as everything in a room is.

## Where they are

A thread is at a place (`Issho.Place`): the same places the components
already share for their cursors and selections, so a thread on a canvas's
node is at `%{"doc" => "board:42", "at" => %{"node" => "n7"}}`, and on a
text's selection at the text's own place. A thread at `nil` is on the
page.

A room's threads are a document of the room: `"board:42/issho.comments"`
(`Issho.Comments.document/1`). It is Issho's own, whatever your policy's
`document/2` says of that id, with its own engine
(`Issho.Engine.Comments`) and its browser twin (`commentsEngine`), and it
is kept in your instance's store like any document.

## Who may comment

A change to the comments asks your policy for `:comment`, not `:write`:

```elixir
def authorize(who, "board:" <> id, :comment), do: Boards.may_comment?(who, id)
```

A person with a read-only grant (`can: :read`) comments when your policy
allows it: a commenter is between a reader and a writer. A policy that
refuses actions it does not know lets no one comment until it says
`:comment`.

## Who wrote it

Each comment names its author and its time, and Issho holds both to the
writer before a change is accepted: the author is whoever made the change,
as their signed identity says (their key, name, kind, avatar, colour, and
whom an agent acts for), and the time is within a few minutes of the
server's clock. A browser cannot write as someone else, or in the past;
only an author edits or deletes their comment, and a reaction is the
reactor's own.

## On the page

`Issho.Components.comments/1` is the room's threads beside your page: the
open and resolved threads, each with its comments, replies, reactions and
edits, a composer, and a mark over the page at each thread's place. In a
LiveView that is in the room, with Issho's hooks in your LiveSocket:

```heex
<.comments id="comments" room={@room}>
  <:place :let={%{place: place, default: default}}>
    {MyApp.Places.label(place) || default}
  </:place>
</.comments>
```

A new comment goes on what the person selected in a component of the
page (their place, as the component shares it), or on the page. The
marks are drawn where each place is on each person's screen, by the
component's own `locate` (see "Building a component on Issho"): Kotoba,
Hakushi and Masu mark their threads with no code of their own, and so
does your component once it says where its places are. A mark opens its
thread in the panel; a thread chosen in the panel scrolls the page to
its place.

Everything goes through the LiveView, as the person it is in the room:
their comments are theirs, at the server's time, under your policy.

## From your server

```elixir
ada = %{id: "user:ada", name: "Ada"}

{:ok, %{thread: thread}} =
  Issho.Comments.start(MyApp.Issho, "board:42", ada, place, "Should this go first?",
    mentions: ["agent:claude"])

{:ok, _} = Issho.Comments.reply(MyApp.Issho, "board:42", ken, thread, "Yes.")
{:ok, _} = Issho.Comments.react(MyApp.Issho, "board:42", ken, thread, comment, "👍")
{:ok, _} = Issho.Comments.resolve(MyApp.Issho, "board:42", ada, thread)
{:ok, threads} = Issho.Comments.threads(MyApp.Issho, "board:42")
```

From a LiveView, an agent's participant or a browser, the same changes
are the comments document's operations (`Issho.Comments.Ops`), committed
as any change, under the policy.

## Events

Each change is an event of the room, once it is saved: `"thread.created"`,
`"comment.created"` (every new comment, with whom it mentions),
`"comment.edited"`, `"comment.deleted"`, `"thread.resolved"` and
`"thread.reopened"`. Send your own notifications from them (an email for
a mention, a badge), with `Issho.Events.subscribe/2` or the
`[:issho, :event]` telemetry event.

## Agents

An agent in the room reads the threads (`list_threads`), writes
(`comment`: a reply, a new thread at a place, at what someone selected,
or on the page), and resolves (`resolve_thread`). Mentioned in a comment,
it hears it:

```text
wait_for_events {"room": "board:42", "names": ["comment.created"], "mentions_me": true}
```

and answers in the thread. Its comments say whom it acts for.

Mentioned while it is not in the room, it finds the comment in its inbox
(`Issho.Inbox`, the `inbox` tool), and your app may wake it
(`:on_mention`): see the Agents guide.
