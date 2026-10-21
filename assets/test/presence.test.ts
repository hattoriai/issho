import { test } from "node:test";
import assert from "node:assert/strict";
import { Presence, type PresenceEvent } from "../src/presence";

const meta = (key: string, ref: string, joined_at: number, extra = {}) => ({
  key,
  name: key,
  avatar: null,
  color: null,
  palette: 1,
  kind: "human",
  on_behalf_of: null,
  joined_at,
  phx_ref: ref,
  ...extra,
});

test("one person per key, however many tabs, without this actor", () => {
  const presence = new Presence("ada");
  presence.syncState({
    ada: { metas: [meta("ada", "1", 10)] },
    ken: { metas: [meta("ken", "2", 20), meta("ken", "3", 30)] },
    claude: { metas: [meta("claude", "4", 5, { kind: "agent" })] },
  } as never);

  assert.deepEqual(presence.others.map((p) => p.key), ["claude", "ken"]);
  assert.equal(presence.everyone.length, 3);
  assert.equal(presence.others[0].kind, "agent");
});

test("diffs announce people who come and go, not tabs", () => {
  const presence = new Presence("ada");
  const events: string[] = [];
  presence.on((event: PresenceEvent) => {
    if (event.type !== "change") events.push(`${event.type}:${event.person.key}`);
  });

  presence.syncState({ ada: { metas: [meta("ada", "1", 1)] } } as never);
  presence.syncDiff({ joins: { ken: { metas: [meta("ken", "2", 2)] } }, leaves: {} } as never);
  presence.syncDiff({ joins: { ken: { metas: [meta("ken", "3", 3)] } }, leaves: {} } as never);
  presence.syncDiff({ joins: {}, leaves: { ken: { metas: [meta("ken", "2", 2)] } } } as never);
  assert.deepEqual(presence.others.map((p) => p.key), ["ken"]);
  presence.syncDiff({ joins: {}, leaves: { ken: { metas: [meta("ken", "3", 3)] } } } as never);

  assert.deepEqual(events, ["join:ken", "leave:ken"]);
  assert.deepEqual(presence.others, []);
});

test("a person writes when any of their tabs may", () => {
  const presence = new Presence("ada");
  presence.syncState({
    ken: { metas: [meta("ken", "1", 1, { can: "read" }), meta("ken", "2", 2, { can: "write" })] },
    sam: { metas: [meta("sam", "3", 3, { can: "read" })] },
  } as never);

  assert.deepEqual(
    presence.others.map((p) => [p.key, p.can]),
    [
      ["ken", "write"],
      ["sam", "read"],
    ],
  );
});
