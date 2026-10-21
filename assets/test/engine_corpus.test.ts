// The cases of test/corpus, which the Elixir tests run against the server's
// engines too: both sides must give the same result.
import { test } from "node:test";
import assert from "node:assert/strict";
import type { Operation, State } from "../src/engine";
import { mapEngine } from "../src/engines/map";
import corpus from "../../test/corpus/engine_map.json";

type Step = { ops: Operation[]; error?: string };
type Example = { name: string; initial: State | null; steps: Step[]; expected: State };

for (const example of corpus as unknown as Example[]) {
  test(`map: ${example.name}`, () => {
    let state: State = example.initial ?? {};
    const before = JSON.stringify(state);
    const initial = state;
    for (const step of example.steps) {
      const result = mapEngine.apply(state, step.ops, "author");
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
