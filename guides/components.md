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

## The page: where a block is

The element that shows a document carries its id:

    <div data-issho-doc={"board:7/plan"}>...</div>

The room is the part before the `"/"`. Issho watches these elements: what
is on the screen, so that agents move for someone who sees them; where
pointers and agents go.

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

On an Issho page, Issho's pointers also keep the one followed on the
screen, and a link or a button with `data-issho-follow` that they click is
clicked for those who follow them.

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

Agents see them with `look_around`, and `point` and `click` them; a click
on one with `data-issho-follow` takes the people who follow the agent
along. An app's own tool can do the same, then act:

    :ok = Issho.Motion.click(participant, %{"anchor" => "new-page"})
    {:ok, page} = Pages.create(attrs)
