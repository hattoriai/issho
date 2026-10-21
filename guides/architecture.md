# Architecture

Issho sits between a page's components and your app. The components bring
what only they know (their model, where someone is in them, their view);
your app brings its login, its permissions and its data; Issho does
everything in between, once, for every component on the page.

## The parts

| Part | Module | One per |
| --- | --- | --- |
| Instance | `Issho` | app |
| Session | `Issho.Channel`, `Issho.Participant` | actor, room and tab |
| Presence | `Issho.Presence` | node (a `Phoenix.Presence`) |
| Awareness | `Issho.Awareness` | room and node |
| Authority | `Issho.Authority` | document, across the cluster |
| Store | your `Issho.Store` | app |
| Policy | your `Issho.Policy` | app |

## A change, from a browser to everyone

1. The browser sends `"tx"` on its room's channel.
2. The session checks the token allows writing, and asks the policy
   (`:write`).
3. The document's authority checks the envelope and its receipt, applies
   the engine, validates, and saves through the store, comparing versions.
4. Only after the save, it answers the author and broadcasts the
   transaction on the document's topic.
5. Every session with the document open asks the policy (`:read`) and
   pushes it to its browser; a session the policy refuses ends.

## Presence and awareness

Who is here changes when people come and go: `Phoenix.Presence` tracks
it, replicated across the cluster. Where they are changes many times a
second: each session sends its state to the room's awareness process on
its node, which sends one frame of what changed every 50 ms to the room's
sessions on every node. Awareness is never saved and never replicated by
Presence; a full frame every few seconds heals a missed one.

## Documents and engines

An authority owns the envelope: the engine's name and version, an epoch,
a revision, the state the epoch began with, the journal and the receipts.
The engine owns the state and its operations, and is pure, so the same
operations give the same state on every node, in a replay, and in the
browser's twin of the engine.

Every document of a room is the room (`"board:42"`) or a path under it
(`"board:42/n7/body"`): the nested documents of a canvas share the room's
people, its policy and its awareness.

## The browser

A page joins each room once (`joinRoom`), however many components share
it. The room holds one channel, its people (`Presence`), its awareness,
and the documents components open. A document is the accepted state, this
browser's pending transactions, and the view: the pending ones replayed
over the accepted state. A change shows at once; transactions go one at a
time, never change once made, and are applied once however often they are
sent. After a reconnect the room opens each document again with its
pending ids, the server says which it already has, and only the others go
again.

The engines come in pairs: `Issho.Engine.Map` and `mapEngine`, held to the
same cases in `test/corpus`. A binding's engine does the same.

## Agents

An agent is an actor like any other. From Elixir it joins with
`Issho.join_as/4` and gets a process with the same session as a browser's
channel: presence, places, locks, transactions and the policy, and the
room's events as messages.
