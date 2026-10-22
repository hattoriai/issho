# Building a component on Issho

Issho gives a component what it would otherwise build alone: a document
everyone edits at once, the people of a room, agents that work as people
do, and a page that is one live space across all its blocks. Kotoba (rich
text), Hakushi (a canvas) and Masu (a grid) are built on it; yours can be
too, and work with theirs on the same page.

This guide is the contract between a component and Issho: what a
component brings, and what it gets.

## The layers

Think of a page in layers:

1. **A block alone.** Your component on a plain page, in its own room: its
   own people, its own cursors, following within itself. It works with or
   without Issho's script on the page.
2. **An Issho page.** Several blocks in one room, with Issho's people list
   and pointers (`Issho.Components.people/1`, `Issho.Components.pointers/1`):
   one set of people, one pointer for each person across every block,
   following across the page, agents going from block to block as one.
3. **Blocks within blocks.** A canvas inside a rich text, a grid inside a
   canvas's node: each block is found by its document's id, wherever it is
   on the page.

A component does the same in each layer: it says what its own places are
and where they are on the screen; Issho does the rest. Every contract
below is plain DOM (a data attribute, a symbol on an element, an event), so
a component needs no import of Issho's script, and a copy of it in one
block's bundle agrees with another's.

## The server: a binding

A component brings its document model as an engine (`Issho.Engine`): how
its operations apply, merge and validate. And the format of a person's
place in it (`Issho.Place`): a caret, a node, a cell.

    defmodule MyCanvas.Issho do
      use Issho.Binding, engine: MyCanvas.Engine, place: MyCanvas.Place
    end

Your app's policy names it as a document's engine (`Issho.Policy`).

### Places are a contract

A place is stored and sent: in a person's state, in an agent's motion,
and, to come, in comments, history and following across pages, which
keep places in an app's tables. So a component's place format is part of
its public API, documented and kept across releases like any other: say
what its `at` is (Kotoba a caret, `%{"anchor" => point, "focus" =>
point}`; Hakushi a node or a point; Masu a cell, `[row_id, key]`),
validate it with its `Issho.Place`, and only add to it.

## Joining: one `issho` option

An app makes every component collaborative the same way: an `issho`
option with the same keys, which the component checks with
`Issho.Join.new!/2`.

    <.kotoba    issho={[instance: MyApp.Issho, document: "page:1/body"]} user={@user} />
    <.canvas    issho={[instance: MyApp.Issho, document: "page:2"]} user={@user} />
    <.data_grid issho={[instance: MyApp.Issho, document: "page:3/rows"]} user={@user} />

`instance` and `document` (whose room is the part before the first
`"/"`), `can`, `people`, `follow`, `on_behalf_of` and `claims`, and the
component's own besides, which it names (`Issho.Join.new!(opts,
[:undo])`); any other key is an error. The person is the component's
`user`, as `Issho.Actor` says them. `Issho.Join.grant_opts/1` gives what
`Issho.Live.grant/4` and `Issho.Live.join/4` take.

## A person's state: Issho's keys, and a component's

A person's awareness state is shared by every component of their page.
Issho owns its top-level keys (`place`, `locks`, `status`, `pointer`,
`view`, `motion`, `path`, `blocks`); a component keeps its own (a
cursor, a viewport, a selection of its own) under its document, in
`blocks`:

    Issho.Live.merge_block(room, "board:42", %{"cursor" => [10, 20]})
    Issho.Participant.aware_block(agent, "board:42", %{"cursor" => [10, 20]})
    Issho.Awareness.block(state, "board:42")      # => %{"cursor" => [10, 20]}

    room.awareBlock("board:42", { cursor: [10, 20] })
    blockOf(peer.state, "board:42")

So two components of a page, or a component and Issho, never write over
each other's keys.

## Who made a change

Every change has an author, an `Issho.Identity`: a person, an agent and
whom it acts for (`on_behalf_of`), or a service (your server's own,
`"server"`). A document's hook gets it as `:by`, beside the `:author`
key the journal keeps; a component gives it to its app's callbacks the
same way, so an app knows who did what, whichever component it was.
Your server's changes name theirs: `Issho.transact/4`'s `:author`, an
actor or a key.

## Events

Something that happened in a room is an `Issho.Event`: a dotted name, the
room, the document, who (`by`) and data. Every document emits
`"document.changed"`; the other names Issho and its components use are
reserved (`Issho.Event`), and an app's own take names of their own.
Subscribe with `Issho.Events.subscribe/2`, and emit with
`Issho.Events.emit/4`: a component that keeps its data outside Issho's
documents (a grid of an app's tables) emits `"document.changed"` for its
own saves, so the room hears of every change the same way.

## The page: where a block is

The element that shows a document carries its id:

    <div data-issho-doc={"board:7/plan"}>...</div>

The room is the part before the `"/"`. Issho watches these elements: what
is on the screen, so that agents move for someone who sees them; where
pointers and agents go.

### A block of another room

A page may hold a block of another room: a canvas shared in its own room,
embedded in a document of the page's room. That block is its room's, and
its room draws its people there: the block itself (a canvas draws its
people's cursors), or that room's own pointers on the page. Issho's
pointers of the page's room hear only that a pointer is in it
(`{ block: doc }`), and draw nothing there, so that no one is drawn twice.
Someone in both rooms (on this page, in the document and in its canvas) is
in both rooms' lists, each list its room's.

### One document, many places

The same document often shows in more than one place: a canvas on its own
page, and the same canvas embedded in a document of another page (a Kotoba
embed), each rendered by its own LiveView. They are one canvas because
they open one document (`"board:42"`), and the document's authority, not
either LiveView, holds it: it runs while anyone has it open, wherever,
and a page that opens it later gets it as it is. Nobody needs to be on the
canvas's own page for its embed to be live.

Three things make it safe:

* **Define the document once, in your policy.** Issho starts a document
  from your policy's `document/2` (`Issho.Policy`) whoever opens it first:
  the page, the embed, an agent. A component may bring its own spec (its
  initial content and hook, `Issho.Live.open/3`'s `:spec`), but it is
  used only when the policy does not know the document, and then the
  first component to open it gives it, whatever the others bring. Two
  places that build their spec apart (another `on_change`, other rules)
  would differ only by who came first; in the policy, they cannot.

      def document(_who, "board:" <> id) do
        board = MyApp.Boards.get!(id)
        Hakushi.Issho.document(board.graph, on_change: &MyApp.Boards.on_change(board, &1, &2))
      end

* **One document id, an element id of each place.** Every copy opens the
  same document id; each has its own DOM id (an embed's slot id, such as
  `"board-" <> embed.id`), since the same document can be embedded twice
  in one page.
* **A reference is the person's input.** An embed keeps only which
  document it shows (a `ref`), and whoever edits the text can put any ref
  there. Load what it shows as the document's own page does, with the
  viewer's permission (`MyApp.Boards.get_for(user, ref)`), and your
  policy's `authorize/3` guards the room as for any page.

Defined in the policy, a document is also open to agents with no browser
at all: an agent's tools open it from `document/2`, and the changes it
makes go through the same hook as everyone's.


deleted from a document) releases its room when it goes
(`Issho.Live.release/2`, from its hook's `destroyed`): the LiveView leaves
the room with its last component, and the room's people see it go.

## Where a place is on the screen: `locate`

Say where a place of your document is in the viewport, so that a pointer,
an agent's or a person's, goes there:

    import { locate } from "issho";

    locate(element, (at) => {
      const node = nodes.get(at.node);
      return node ? node.el.getBoundingClientRect() : null;
    });

`at` is in your document's terms, as your place format says it. Without
Issho's script, set the function on the element under
`Symbol.for("issho.locator")`. Kotoba locates a caret, Hakushi a point of
the canvas or a node, Masu a cell or a range.

## What is under a pointer: `point`

Say which place of your document is under a point of the screen:

    import { point } from "issho";

    point(element, (clientX, clientY) => ({ point: toCanvas(clientX, clientY) }));

A place may say where in its box the pointer is, as fractions of it
(`x`, `y` from 0 to 1, a cell's `{cell: ..., x: 0.25, y: 0.5}`); each page
then draws the pointer at that spot of the place's box (`locate`), else at
its far corner (the end of a caret, a point).

Over your block, a person's pointer is then a place of your document,
which each browser draws where it is on its own screen: the same cell in
another sort order, the same point of a canvas panned elsewhere. One
pointer goes from block to block, and into a block within a block. Without
Issho's script: `Symbol.for("issho.point")`.

A block that draws its people's cursors itself, and says nothing of its
points, carries `data-issho-cursor="own"`; Issho's pointers leave it alone.
On an Issho page, a block that says its points should leave the drawing to
Issho's pointers (look for `.issho-pointers` on the page).

## Agents: tools and motion

Give agents your component's verbs as tools (`Issho.Tool`): read, point,
change, in your document's terms. Move the agent with `Issho.Motion`, so
that it goes where it works as a person would, and the people follow it:

    # To a node, then a drag of it, then the change.
    :ok = Issho.Motion.go(participant, %{"doc" => doc, "at" => %{"node" => id}})
    :ok = Issho.Motion.go(participant, %{"doc" => doc, "at" => %{"point" => [x, y]}},
            gesture: :drag, aware: %{"dragging" => [[id, x, y]]})
    {:ok, _} = Issho.Participant.transact(participant, doc, ops)

Only where it goes is sent; each browser draws the way; the agent waits as
long as that takes, within the tool call's budget, and only when someone
sees your block. `aware` carries your component's own state with the same
gesture (a canvas's cursor and selection). `Issho.Motion.pause/4` is a
moment before a change, for the people to see what will change. Give your
component its own `travel` setting, passed as `travel:`, for apps that
want its changes at once.

In the browser, draw others' moves of your own marks (a caret, a selected
cell, a dragged node) as moves, not jumps: keep the mark, and let it glide
there, in the time the gesture says (`motion.ms` in the agent's state) or
by its distance.

## Following

Following is a room's. The page keeps whom each room follows: the root
element's `data-issho-following`, a JSON object of room to the key of the
one followed, and the `issho:following` event on `document`, `{ room, key }`,
when it changes.

- **Show the one followed, in your terms**: their view of a grid, their
  viewport of a canvas, their caret in a text. Someone followed who is not
  in your block may be in another block of the room: wait for them.
- **Follow, or stop**, from your own controls (a list of people in your
  block): `follow(room, key)` of `issho`, or write the attribute and send
  the event yourself. Mark a control that follows or stops with
  `data-issho-follow-control`.
- **Stop when the person goes their own way in your block**: a scroll, a
  press, a key (`stopOnOwnWay(room, element)`).
- **Say whom you follow, in Issho's look**: a block that lists its own
  people shows "Following Ada" with Stop, with the classes
  `issho-following` and `issho-following-stop`, `--issho-color` set to the
  person's colour, and a ring around the block. The look is Issho's (its
  stylesheet styles these classes) and its properties are the app's, the
  same for every block of the page: `--issho-following-background`,
  `--issho-following-text`, `--issho-following-ring` (a box-shadow, or
  `none`). A block that may be on a page without Issho's stylesheet styles
  the classes the same way itself, with the same properties.
- **Let the app turn following off for your block**: a `follow` option
  (`follow={false}`) under which it follows no one and shows no one
  followed.

On an Issho page, Issho's pointers also keep the one followed on the
screen, and a link or a button with `data-issho-follow` that they click is
clicked for those who follow them. When the one followed goes into a block
of another room, the page keeps the block on the screen and follows them
in that room too, so the block shows where they are; when they come out,
or the page stops following, the block stops. A block that follows someone
in its own room (from its own list of people) keeps itself on the screen:
it scrolls into view when they move it.

## Motion

How much a person wants to see others move is the app's to say: the root
element's `data-issho-motion` (`full` or `reduced`), else the browser's
"reduce motion" setting, and the `issho:motion` event when it changes.
Honor it: no gliding, no sweeping, for `reduced`.

    :root[data-issho-motion="reduced"] .my-cursor { transition: none; }

## Elements of the page

Your app's own elements become places an agent can point at and click:

    <button data-issho-anchor="new-page" phx-click="new_page">New page</button>
    <.link navigate={~p"/pages/1/edit"} data-issho-anchor="edit" data-issho-follow>Edit together</.link>

Agents see them with `look_around` (a link with where it goes, its
`href`), and `point` and `click` them; a click on one with
`data-issho-follow` takes the people who follow the agent along. An agent
also goes to a page by its path (the `navigate` tool,
`Issho.Motion.navigate/2`), and takes its followers there; to work in that
page's documents it joins its room, which the app's own tools can tell it
(a page's room). An app's own tool can do the same, then act:

    :ok = Issho.Motion.click(participant, %{"anchor" => "new-page"})
    {:ok, page} = Pages.create(attrs)
