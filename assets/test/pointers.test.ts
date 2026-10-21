import { test } from "node:test";
import assert from "node:assert/strict";
import { fractions, place, pointing } from "../src/pointers";
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
