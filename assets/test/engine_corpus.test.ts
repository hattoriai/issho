// The cases of test/corpus, which the Elixir tests run against the server's
// engines too: both sides must give the same result.
import { test } from "node:test";
import assert from "node:assert/strict";
import type { Engine, Operation, State } from "../src/engine";
import { mapEngine } from "../src/engines/map";
import { commentsEngine } from "../src/engines/comments";
import mapCorpus from "../../test/corpus/engine_map.json";
import commentsCorpus from "../../test/corpus/engine_comments.json";

// A step's author is the key of whoever makes it ("author" unless given).
type Step = { ops: Operation[]; error?: string; author?: string };
type Example = { name: string; initial: State | null; steps: Step[]; expected: State };

const corpora: [string, Engine, unknown][] = [
  ["map", mapEngine, mapCorpus],
  ["comments", commentsEngine, commentsCorpus],
];

for (const [name, engine, corpus] of corpora) {
  for (const example of corpus as Example[]) {
    test(`${name}: ${example.name}`, () => {
      let state: State = example.initial ?? {};
      const before = JSON.stringify(state);
      const initial = state;
      for (const step of example.steps) {
        const result = engine.apply(state, step.ops, step.author ?? "author");
        if (step.error) {
          assert.equal(result.ok, false, `step ${JSON.stringify(step.ops)} should fail`);
          if (!result.ok) assert.equal(result.reason, step.error);
        } else {
          assert.equal(result.ok, true, `step ${JSON.stringify(step.ops)}: ${result.ok ? "" : result.reason}`);
          if (result.ok) state = result.state;
        }
      }
      assert.deepEqual(state, example.expected);
      // The engine never changes the state it is given.
      assert.equal(JSON.stringify(initial), before);
    });
  }
}
