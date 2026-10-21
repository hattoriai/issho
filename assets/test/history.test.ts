import { test } from "node:test";
import assert from "node:assert/strict";
import { PageHistory, type HistoryOwner } from "../src/history";

// A component with its own steps, as a text editor keeps them.
class Component implements HistoryOwner {
  steps: string[] = [];
  undone: string[] = [];
  constructor(readonly name: string, readonly history: PageHistory) {}
  change(step: string): void { this.steps.push(step); this.undone = []; this.history.record(this); }
  undo(): boolean { const step = this.steps.pop(); if (!step) return false; this.undone.push(step); return true; }
  redo(): boolean { const step = this.undone.pop(); if (!step) return false; this.steps.push(step); return true; }
  clearRedo(): void { this.undone = []; }
}

test("undo takes back the last change on the page, wherever it was made", () => {
  const history = new PageHistory();
  const one = new Component("one", history);
  const two = new Component("two", history);
  one.change("a");
  two.change("b");
  one.change("c");

  assert.equal(history.undo(), true);
  assert.deepEqual([one.steps, two.steps], [["a"], ["b"]]);
  assert.equal(history.undo(), true);
  assert.deepEqual([one.steps, two.steps], [["a"], []]);
  assert.equal(history.redo(), true);
  assert.deepEqual([one.steps, two.steps], [["a"], ["b"]]);
  assert.equal(history.canRedo, true);
});

test("a new change anywhere forgets what could be redone everywhere", () => {
  const history = new PageHistory();
  const one = new Component("one", history);
  const two = new Component("two", history);
  one.change("a");
  history.undo();
  two.change("b");
  assert.equal(history.canRedo, false);
  assert.deepEqual(one.undone, []);
  assert.equal(history.redo(), false);
});

test("a component that left takes its steps with it", () => {
  const history = new PageHistory();
  const one = new Component("one", history);
  const two = new Component("two", history);
  one.change("a");
  two.change("b");
  history.forget(two);
  history.undo();
  assert.deepEqual(one.steps, []);
  assert.equal(history.canUndo, false);
});
