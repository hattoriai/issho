import { test } from "node:test";
import assert from "node:assert/strict";
import { atWork } from "../src/agents";
import type { Person } from "../src/presence";
import type { Peer } from "../src/awareness";

const person = (key: string, extra: Partial<Person> = {}): Person => ({
  key, name: key, avatar: null, color: null, palette: 2, kind: "human", on_behalf_of: null, joined_at: 1, can: "write", ...extra,
});

test("the agents with a task, once each, and whether they work for this person", () => {
  const ada = person("ada");
  const everyone = [ada, person("claude", { kind: "agent", on_behalf_of: ada }), person("bot", { kind: "agent" }), person("idle", { kind: "agent" })];
  const task = { title: "Plan", steps: [{ label: "Read", state: "active" }], state: "working" };
  const peers: Peer[] = [
    { session: "s1", key: "claude", state: { task } },
    { session: "s2", key: "bot", state: { task: { ...task, title: "Tidy", state: "paused", by: { key: "ada", name: "Ada" } } } },
    { session: "s3", key: "idle", state: { task: null } },
    { session: "s4", key: "ada", state: { status: "Reading" } },
  ];

  const agents = atWork(peers, everyone, "ada");
  assert.deepEqual(agents.map((one) => [one.agent.key, one.task.title, one.task.state, one.mine]), [
    ["claude", "Plan", "working", true],
    ["bot", "Tidy", "paused", false],
  ]);
  assert.deepEqual(atWork(peers, everyone, "ken").map((one) => one.mine), [false, false]);
});
