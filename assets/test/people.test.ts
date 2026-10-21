import { test } from "node:test";
import assert from "node:assert/strict";
import { describe, someone } from "../src/people";
import type { Person } from "../src/presence";

const person = (key: string, extra: Partial<Person> = {}): Person => ({
  key, name: key, avatar: null, color: null, palette: 1, kind: "human", on_behalf_of: null, joined_at: 1, can: "write", ...extra,
});

test("this actor comes first, each with what they say they are doing", () => {
  const ada = person("ada");
  const claude = person("claude", { name: "Claude Code", kind: "agent", on_behalf_of: ada });
  const people = someone([claude, ada], [{ session: "s1", key: "claude", state: { status: "Renaming" } }], "ada");
  assert.deepEqual(people.map((one) => [one.person.key, one.you, one.status]), [["ada", true, null], ["claude", false, "Renaming"]]);
});

test("an agent says for whom it acts, the app says it is the app, a viewer is viewing", () => {
  const ada = person("ada", { name: "Ada" });
  assert.equal(describe({ person: person("claude", { name: "Claude Code", kind: "agent", on_behalf_of: ada }), status: "Renaming", you: false }), "Claude Code, an agent for Ada: Renaming");
  assert.equal(describe({ person: person("bot", { name: "Bot", kind: "service" }), status: null, you: false }), "Bot, the app");
  assert.equal(describe({ person: person("ken", { name: "Ken", can: "read" }), status: null, you: false }), "Ken, viewing");
  assert.equal(describe({ person: ada, status: null, you: true }), "Ada (you)");
});
