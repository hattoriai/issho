import { test } from "node:test";
import assert from "node:assert/strict";
import { markSpot } from "../src/comments";

test("a thread's mark is at its place's top right corner, in the viewport", () => {
  const viewport = { width: 800, height: 600 };
  assert.deepEqual(markSpot({ left: 100, top: 200, width: 300, height: 20 }, viewport), { x: 388, y: 188 });
  // At the viewport's edges, held inside it.
  assert.deepEqual(markSpot({ left: 700, top: 5, width: 200, height: 40 }, viewport), { x: 776, y: 0 });
  // A place off the screen has no mark.
  assert.equal(markSpot({ left: 100, top: 700, width: 100, height: 20 }, viewport), null);
  assert.equal(markSpot({ left: 100, top: -50, width: 100, height: 20 }, viewport), null);
});
