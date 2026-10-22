import { test } from "node:test";
import assert from "node:assert/strict";
import { Awareness, blockOf, withBlock, type AwarenessState } from "../src/awareness";

// A clock and timers the test moves by hand.
function clock() {
  let now = 0;
  const timers: { at: number; fn: () => void }[] = [];
  return {
    now: () => now,
    setTimer: (fn: () => void, ms: number) => {
      const timer = { at: now + ms, fn };
      timers.push(timer);
      return timer;
    },
    clearTimer: (timer: unknown) => {
      const index = timers.indexOf(timer as never);
      if (index >= 0) timers.splice(index, 1);
    },
    advance(ms: number) {
      now += ms;
      for (const timer of timers.filter((t) => t.at <= now)) {
        timers.splice(timers.indexOf(timer), 1);
        timer.fn();
      }
    },
  };
}

test("sends the latest state, at most once an interval", async () => {
  const time = clock();
  const sent: (AwarenessState | null)[] = [];
  const awareness = new Awareness(async (state) => sent.push(state), { interval: 50, ...time });

  awareness.set({ place: "a" });
  time.advance(0);
  awareness.set({ place: "b" });
  awareness.set({ place: "c", status: "active" });
  time.advance(20);
  assert.deepEqual(sent, [{ place: "a" }]);
  time.advance(30);
  assert.deepEqual(sent, [{ place: "a" }, { place: "c", status: "active" }]);

  awareness.set({ status: null });
  time.advance(50);
  awareness.clear();
  time.advance(50);
  assert.deepEqual(sent.slice(2), [{ place: "c" }, null]);
});

test("keeps peers per node: full frames replace, gone sessions leave, silent nodes expire", () => {
  const time = clock();
  const awareness = new Awareness(async () => undefined, { staleAfter: 1000, ...time });
  const keys = () => awareness.peers.map((p) => p.key).sort();

  awareness.receive({ node: "a", full: false, states: { s1: { key: "ada", state: { p: 1 } } }, gone: [] });
  awareness.receive({ node: "b", full: false, states: { s2: { key: "ken", state: { p: 2 } } }, gone: [] });
  assert.deepEqual(keys(), ["ada", "ken"]);

  awareness.receive({ node: "a", full: true, states: { s3: { key: "mei", state: {} } }, gone: [] });
  assert.deepEqual(keys(), ["ken", "mei"]);

  awareness.receive({ node: "b", full: false, states: {}, gone: ["s2"] });
  assert.deepEqual(keys(), ["mei"]);

  time.advance(1500);
  assert.deepEqual(keys(), []);
});

test("the sessions that were in the room when this browser joined it: each node's first full frame", () => {
  const awareness = new Awareness(async () => undefined);
  awareness.receive({ node: "a", full: false, states: { moved: { key: "ada", state: { p: 1 } } }, gone: [] });
  awareness.receive({ node: "a", full: true, states: { moved: { key: "ada", state: { p: 1 } }, idle: { key: "ken", state: { p: 2 } } }, gone: [] });
  awareness.receive({ node: "a", full: true, states: { later: { key: "mei", state: { p: 3 } } }, gone: [] });
  awareness.receive({ node: "b", full: true, states: { far: { key: "kai", state: { p: 4 } } }, gone: [] });
  assert.deepEqual(["moved", "idle", "later", "far"].map((s) => awareness.wasThere(s)), [true, true, false, true]);
  // Joined again, after a disconnect: what is there then.
  awareness.reset();
  awareness.receive({ node: "a", full: true, states: { later: { key: "mei", state: { p: 3 } } }, gone: [] });
  assert.deepEqual(["idle", "later"].map((s) => awareness.wasThere(s)), [false, true]);
});

test("a component's own keys go under its document, apart from Issho's and the others'", () => {
  let state: AwarenessState = { place: { doc: "board:1", at: {} } };
  state = { ...state, blocks: withBlock(state, "board:1", { cursor: [1, 2], viewport: [0, 0, 9, 9] }) };
  state = { ...state, blocks: withBlock(state, "board:1/rows", { view: "mine" }) };
  assert.deepEqual(blockOf(state, "board:1"), { cursor: [1, 2], viewport: [0, 0, 9, 9] });
  assert.deepEqual(blockOf(state, "board:1/rows"), { view: "mine" });
  assert.deepEqual(blockOf(state, "elsewhere"), {});
  assert.deepEqual(state.place, { doc: "board:1", at: {} });
  // null removes a key; a block with none goes, and then the blocks.
  state = { ...state, blocks: withBlock(state, "board:1", { cursor: null, viewport: null }) };
  assert.deepEqual(Object.keys(state.blocks as object), ["board:1/rows"]);
  assert.equal(withBlock(state, "board:1/rows", { view: null }), null);
});
