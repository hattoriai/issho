import { test } from "node:test";
import assert from "node:assert/strict";
import { registerEngine, type State } from "../src/engine";
import { mapEngine } from "../src/engines/map";
import { Refused, type AcceptedTransaction, type Transaction } from "../src/document";
import { Room, type RoomTransport } from "../src/room";

registerEngine(mapEngine);

// A transport over a fake server with one map document per id. `drop()`
// loses the connection; `restore()` rejoins, as Phoenix does.
class FakeTransport implements RoomTransport {
  handlers = new Map<string, (payload: never) => void>();
  statusCallbacks: ((status: "joined" | "closed") => void)[] = [];
  pushes: { event: string; payload: unknown }[] = [];
  connected = true;
  docs = new Map<string, { epoch: string; revision: number; state: State; receipts: Map<string, number> }>();

  async join() {
    return { session: "s1", can: "write" as const };
  }

  async push(event: string, payload: unknown): Promise<unknown> {
    this.pushes.push({ event, payload });
    await Promise.resolve();
    if (!this.connected) throw new Error("disconnected");
    if (event === "open") {
      const { doc, pending } = payload as { doc: string; pending: string[] };
      const d = this.doc(doc);
      return { id: doc, engine: "map", epoch: d.epoch, revision: d.revision, state: d.state, accepted: pending.filter((id) => d.receipts.has(id)) };
    }
    if (event === "tx") {
      const { doc, tx } = payload as { doc: string; tx: Transaction };
      return this.commit(doc, tx, "ada", true);
    }
    return {};
  }

  commit(doc: string, tx: Transaction, author: string, deliver: boolean) {
    const d = this.doc(doc);
    const known = d.receipts.get(tx.id);
    if (known) return { id: tx.id, revision: known, duplicate: true };
    const applied = mapEngine.apply(d.state, tx.ops, author);
    if (!applied.ok) throw new Refused(applied.reason);
    d.state = applied.state;
    d.revision += 1;
    d.receipts.set(tx.id, d.revision);
    const event: AcceptedTransaction = { ...tx, revision: d.revision, author };
    if (deliver) queueMicrotask(() => this.emit("tx", { doc, event }));
    return { id: tx.id, revision: d.revision };
  }

  doc(id: string) {
    if (!this.docs.has(id)) this.docs.set(id, { epoch: "e1", revision: 0, state: {}, receipts: new Map() });
    return this.docs.get(id)!;
  }

  on(event: string, callback: (payload: never) => void) {
    this.handlers.set(event, callback);
  }
  onStatus(callback: (status: "joined" | "closed") => void) {
    this.statusCallbacks.push(callback);
  }
  emit(event: string, payload: unknown) {
    this.handlers.get(event)?.(payload as never);
  }
  drop() {
    this.connected = false;
    this.statusCallbacks.forEach((cb) => cb("closed"));
  }
  restore() {
    this.connected = true;
    this.statusCallbacks.forEach((cb) => cb("joined"));
  }
  leave() {}
}

const tick = async () => {
  for (let i = 0; i < 20; i++) await new Promise((resolve) => setImmediate(resolve));
};

test("joins, and opens each document once for every component that asks", async () => {
  const transport = new FakeTransport();
  const room = new Room(transport, { self: "ada" });
  await room.connect();
  assert.equal(room.status, "live");
  assert.equal(room.session, "s1");

  const [a, b] = await Promise.all([room.open("board:1"), room.open("board:1")]);
  assert.equal(a, b);
  assert.equal(transport.pushes.filter((p) => p.event === "open").length, 1);
});

test("changes reach the server, and the others' changes arrive", async () => {
  const transport = new FakeTransport();
  const room = new Room(transport, { self: "ada" });
  await room.connect();
  const doc = await room.open("board:1");

  doc.change([{ op: "set", path: ["title"], value: "Plan" }]);
  await tick();
  assert.equal(doc.pending.length, 0);
  assert.deepEqual(transport.doc("board:1").state, { title: "Plan" });

  // Ken's change, pushed by the channel.
  const event = transport.commit("board:1", { id: "k1", epoch: "e1", base_revision: 1, ops: [{ op: "set", path: ["by"], value: "ken" }] }, "ken", false);
  transport.emit("tx", { doc: "board:1", event: { id: "k1", epoch: "e1", base_revision: 1, ops: [{ op: "set", path: ["by"], value: "ken" }], revision: event.revision, author: "ken" } });
  assert.deepEqual(doc.state, { title: "Plan", by: "ken" });
});

test("a reconnect opens documents again and sends only what the server lacks", async () => {
  const transport = new FakeTransport();
  const room = new Room(transport, { self: "ada" });
  const statuses: string[] = [];
  room.onStatus((status) => statuses.push(status));
  await room.connect();
  const doc = await room.open("board:1");

  transport.drop();
  assert.equal(room.status, "offline");
  doc.change([{ op: "increment", path: ["n"], by: 1 }]);
  doc.change([{ op: "increment", path: ["n"], by: 2 }]);
  // One of them reached the server before the drop, but its reply was lost.
  transport.commit("board:1", doc.pending[0], "ada", false);
  await tick();

  transport.restore();
  await tick();
  assert.equal(room.status, "live");
  assert.deepEqual(statuses, ["live", "offline", "live"]);
  assert.equal(doc.pending.length, 0);
  assert.deepEqual(transport.doc("board:1").state, { n: 3 });
  assert.deepEqual(doc.state, { n: 3 });
});

test("awareness frames become peers; a dropped connection forgets them", async () => {
  const transport = new FakeTransport();
  const room = new Room(transport, { self: "ada" });
  await room.connect();

  transport.emit("aware", { node: "n1", full: false, states: { s2: { key: "ken", state: { place: { doc: "board:1" } } } }, gone: [] });
  assert.deepEqual(room.awareness.peers.map((p) => p.key), ["ken"]);

  transport.drop();
  assert.deepEqual(room.awareness.peers, []);
});

test("bye ends the room with its reason", async () => {
  const transport = new FakeTransport();
  const room = new Room(transport, { self: "ada" });
  const reasons: (string | undefined)[] = [];
  room.onStatus((status, reason) => status === "ended" && reasons.push(reason));
  await room.connect();

  transport.emit("bye", { reason: "revoked" });
  assert.equal(room.status, "ended");
  assert.deepEqual(reasons, ["revoked"]);
  transport.restore();
  assert.equal(room.status, "ended");
});

import { MemoryDraftStore, claimSession } from "../src/drafts";

// One tab's session storage, and Web Locks the test holds by hand.
function tab() {
  const storage = new Map<string, string>();
  const held = new Set<string>();
  return {
    storage: { getItem: (k: string) => storage.get(k) ?? null, setItem: (k: string, v: string) => void storage.set(k, v) },
    locks: {
      request: (name: string, _opts: unknown, callback: (lock: unknown) => unknown) => {
        if (held.has(name)) return Promise.resolve(callback(null));
        held.add(name);
        return Promise.resolve(callback({ name }));
      },
    } as never,
    copy() {
      // A duplicated tab: the same session storage, the same locks.
      return { storage: this.storage, locks: this.locks };
    },
  };
}

test("unsent changes survive a reload, and are sent once", async () => {
  const transport = new FakeTransport();
  const drafts = new MemoryDraftStore();
  const session = tab();
  const before = new Room(transport, { self: "ada", room: "board:1", drafts, session });
  await before.connect();
  const doc = await before.open("board:1");

  transport.drop();
  doc.change([{ op: "increment", path: ["n"], by: 1 }]);
  doc.change([{ op: "increment", path: ["n"], by: 2 }]);
  // One reached the server before the drop; its reply was lost.
  transport.commit("board:1", doc.pending[0], "ada", false);
  await before.flushDrafts();
  assert.equal(drafts.drafts.size, 1);

  // The reload: a new room in the same tab, online again.
  transport.connected = true;
  const after = new Room(transport, { self: "ada", room: "board:1", drafts, session: { ...session, locks: null } });
  await after.connect();
  const reopened = await after.open("board:1");
  assert.deepEqual(reopened.state, { n: 3 });
  await tick();
  await after.flushDrafts();

  assert.deepEqual(transport.doc("board:1").state, { n: 3 });
  assert.equal(reopened.pending.length, 0);
  assert.equal(drafts.drafts.size, 0);
});

test("a draft of another epoch is reported and kept aside, never sent", async () => {
  const transport = new FakeTransport();
  const drafts = new MemoryDraftStore();
  const session = tab();
  const before = new Room(transport, { self: "ada", room: "board:1", drafts, session });
  await before.connect();
  const doc = await before.open("board:1");
  transport.drop();
  doc.change([{ op: "set", path: ["mine"], value: "draft" }]);
  await before.flushDrafts();

  // The document was replaced meanwhile.
  transport.connected = true;
  transport.doc("board:1").epoch = "e2";
  const after = new Room(transport, { self: "ada", room: "board:1", drafts, session: { ...session, locks: null } });
  const stale: string[] = [];
  after.onStaleDraft(({ document, draft, reason }) => stale.push(`${document}:${reason}:${draft.pending.length}`));
  await after.connect();
  const reopened = await after.open("board:1");
  await tick();

  assert.deepEqual(stale, ["board:1:epoch_mismatch:1"]);
  assert.equal(reopened.pending.length, 0);
  assert.deepEqual(transport.doc("board:1").state, {});
  assert.equal([...drafts.drafts.keys()].filter((k) => k.endsWith(":stale")).length, 1);

  await after.discardStaleDraft("board:1");
  assert.equal([...drafts.drafts.keys()].filter((k) => k.endsWith(":stale")).length, 0);
});

test("a tab keeps its session across reloads; a duplicated tab gets its own", async () => {
  const first = tab();
  let n = 0;
  const id = () => `s${++n}`;
  const session = await claimSession("scope", { ...first, newId: id });
  // The same tab after a reload: its lock went with the old page.
  const reloaded = await claimSession("scope", { storage: first.storage, locks: null, newId: id });
  assert.equal(reloaded, session);
  // A duplicated tab copied the storage, but the first tab holds the lock.
  const duplicate = await claimSession("scope", { ...first.copy(), newId: id });
  assert.notEqual(duplicate, session);
});
