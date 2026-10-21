import { test } from "node:test";
import assert from "node:assert/strict";
import { fractions, gestureTracker, place, pointing, roomOf, within } from "../src/pointers";
import type { Person } from "../src/presence";
import type { Peer } from "../src/awareness";

const person = (key: string, extra: Partial<Person> = {}): Person => ({
  key, name: key, avatar: null, color: null, palette: 3, kind: "human", on_behalf_of: null, joined_at: 1, can: "write", ...extra,
});

test("a pointer is a point of its element, as fractions of its box", () => {
  const box = { left: 100, top: 50, width: 200, height: 100 };
  assert.deepEqual(fractions(box, 150, 75), { x: 0.25, y: 0.25 });
  // Outside the box, held at its sides.
  assert.deepEqual(fractions(box, 0, 500), { x: 0, y: 1 });
  assert.deepEqual(fractions({ left: 0, top: 0, width: 0, height: 0 }, 5, 5), { x: 0, y: 0 });
});

test("each browser draws it where the element is on its own page, or at the edge it is beyond", () => {
  const viewport = { width: 800, height: 600 };
  // The same pointer, an element that is elsewhere on another person's page.
  assert.deepEqual(place({ left: 400, top: 300, width: 200, height: 100 }, { x: 0.25, y: 0.5 }, viewport), { x: 450, y: 350, edge: null });
  assert.deepEqual(place({ left: 100, top: 900, width: 200, height: 100 }, { x: 0.5, y: 0.5 }, viewport), { x: 200, y: 588, edge: "bottom" });
  assert.deepEqual(place({ left: 100, top: -400, width: 200, height: 100 }, { x: 0.5, y: 0.5 }, viewport), { x: 200, y: 12, edge: "top" });
  assert.deepEqual(place({ left: 900, top: 100, width: 200, height: 100 }, { x: 0, y: 0 }, viewport), { x: 788, y: 100, edge: "right" });
});

test("the others, one each, never this actor; an agent at the document it works in, and where", () => {
  const everyone = [person("ada", { name: "Ada" }), person("ken", { name: "Ken", color: "#be185d" }), person("claude", { name: "Claude", kind: "agent" })];
  const peers: Peer[] = [
    { session: "s1", key: "ada", state: { pointer: { anchor: "#title", x: 0.5, y: 0.5 } } },
    { session: "s2", key: "ken", state: { place: { doc: "notebook:7/intro", at: {} } } },
    { session: "s3", key: "ken", state: { pointer: { anchor: "page", x: 2, y: 0.1, click: 3 } } },
    { session: "s4", key: "claude", state: { place: { doc: "notebook:7/tasks", at: { cell: [1, "name"] } } } },
    { session: "s5", key: "nobody", state: { status: "Thinking" } },
  ];
  assert.deepEqual(pointing(peers, everyone, "ada"), [
    { key: "claude", name: "Claude", color: "var(--issho-person-3)", kind: "agent", pointer: null, doc: "notebook:7/tasks", at: { cell: [1, "name"] } },
    { key: "ken", name: "Ken", color: "#be185d", kind: "human", pointer: { anchor: "page", x: 1, y: 0.1, click: 3 }, doc: null },
  ]);
});

test("a pointer that is not one is none", () => {
  const peers: Peer[] = [
    { session: "s1", key: "ken", state: { pointer: { anchor: 4, x: 0, y: 0 } } },
    { session: "s2", key: "eve", state: { pointer: { anchor: "#a", x: "0", y: 0 } } },
  ];
  assert.deepEqual(pointing(peers, [], "ada"), []);
});

test("a located place says where in its box the pointer is, else its far corner", () => {
  assert.deepEqual(within({ cell: [1, "name"], x: 0.25, y: 0.5 }), { x: 0.25, y: 0.5 });
  assert.deepEqual(within({ anchor: {}, focus: {} }), { x: 1, y: 1 });
  assert.deepEqual(within({ x: 3, y: -1 }), { x: 1, y: 1 });
  assert.deepEqual(within(null), { x: 1, y: 1 });
});

test("a pointer in a block of another room is that room's: the page hears which block, and draws none", () => {
  const peers: Peer[] = [
    { session: "s1", key: "ken", state: { pointer: { block: "canvas:9" } } },
    { session: "s2", key: "eve", state: { pointer: { block: "" } } },
  ];
  assert.deepEqual(pointing(peers, [person("ken", { name: "Ken" })], "ada"), [
    { key: "ken", name: "Ken", color: "var(--issho-person-3)", kind: "human", pointer: null, doc: "canvas:9", away: true },
  ]);
});

test("the room of a document is the part of its id before the first slash", () => {
  assert.equal(roomOf("notebook:7/intro/a"), "notebook:7");
  assert.equal(roomOf("canvas:9"), "canvas:9");
});

test("each gesture of an agent is new once, per session; one made before the page came is not", () => {
  const track = gestureTracker();
  const gesture = (seq: number, gesture = "click") => ({ motion: { to: { anchor: "edit" }, gesture, ms: 300, seq } });
  // The room's states reach the page late: none at first, then an agent
  // that clicked before the page came (it was there when the page joined),
  // and one that has only joined.
  const there = new Set(["old"]);
  const wasThere = (session: string) => there.has(session);
  assert.deepEqual([...track([], wasThere).fresh], []);
  let peers: Peer[] = [
    { session: "old", key: "claude", state: gesture(12) },
    { session: "new", key: "claude", state: { status: "Joined" } },
  ];
  assert.deepEqual([...track(peers, wasThere).fresh], []);
  assert.deepEqual([...track(peers, wasThere).fresh], []);
  // The second session's first gesture is new, once; the first one's stays done.
  peers = [peers[0]!, { session: "new", key: "claude", state: gesture(1, "point") }];
  const gestures = track(peers, wasThere);
  assert.deepEqual([...gestures.fresh], ["new"]);
  assert.equal(gestures.latest.get("claude"), "new");
  assert.deepEqual([...track(peers, wasThere).fresh], []);
  // Drawn: the session of its last gesture, and that it is new.
  const drawn = pointing(peers, [person("claude", { kind: "agent" })], "ada", gestures);
  assert.deepEqual(drawn[0]?.motion, { gesture: "point", ms: 300, seq: 1, fresh: true });
  assert.equal(pointing(peers, [person("claude", { kind: "agent" })], "ada", track(peers, wasThere))[0]?.motion?.fresh, undefined);
  // An agent that comes after the page, with a gesture at once: it is new.
  assert.deepEqual([...track([...peers, { session: "later", key: "gemini", state: gesture(1, "navigate") }], wasThere).fresh], ["later"]);
});
