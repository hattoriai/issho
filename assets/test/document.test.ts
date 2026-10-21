import { test } from "node:test";
import assert from "node:assert/strict";
import { registerEngine, type State } from "../src/engine";
import { mapEngine } from "../src/engines/map";
import {
  Refused,
  SharedDocument,
  type AcceptedTransaction,
  type DocumentLink,
  type Receipt,
  type Snapshot,
  type Transaction,
} from "../src/document";

registerEngine(mapEngine);

// A server with the authority's rules (Issho.Authority): one order,
// receipts, the engine, and each accepted transaction pushed to every
// browser after the reply, as a channel does.
class FakeServer {
  epoch = "e1";
  revision = 0;
  state: State;
  receipts = new Map<string, number>();
  browsers: { doc: SharedDocument; author: string; inbox: AcceptedTransaction[] }[] = [];
  sends: string[] = [];
  online = true;
  constructor(initial: State = {}) {
    this.state = initial;
  }

  snapshot(accepted: string[] = []): Snapshot {
    return { id: "d", engine: "map", epoch: this.epoch, revision: this.revision, state: this.state, accepted };
  }

  connect(author: string): SharedDocument {
    const browser = { author, inbox: [] as AcceptedTransaction[], doc: undefined as unknown as SharedDocument };
    const link: DocumentLink = { send: (_id, tx) => this.commit(tx, author) };
    let n = 0;
    browser.doc = new SharedDocument(this.snapshot(), link, { author, newId: () => `${author}-${++n}` });
    this.browsers.push(browser);
    return browser.doc;
  }

  async commit(tx: Transaction, author: string): Promise<Receipt> {
    this.sends.push(tx.id);
    await Promise.resolve();
    if (!this.online) throw new Error("disconnected");
    const known = this.receipts.get(tx.id);
    if (known !== undefined) return { id: tx.id, revision: known, duplicate: true };
    if (tx.epoch !== this.epoch) throw new Refused("epoch_mismatch");
    const applied = mapEngine.apply(this.state, tx.ops, author);
    if (!applied.ok) throw new Refused(applied.reason);
    this.state = applied.state;
    this.revision += 1;
    this.receipts.set(tx.id, this.revision);
    const event: AcceptedTransaction = { ...tx, revision: this.revision, author };
    for (const browser of this.browsers) browser.inbox.push(event);
    return { id: tx.id, revision: this.revision };
  }

  // Delivers queued events, as the channel's pushes after its replies.
  deliver(): void {
    for (const browser of this.browsers) {
      for (const event of browser.inbox.splice(0)) browser.doc.receive(event);
    }
  }

  async settle(): Promise<void> {
    for (let i = 0; i < 50; i++) {
      await new Promise((resolve) => setImmediate(resolve));
      this.deliver();
    }
  }
}

const set = (key: string, value: number | string) => ({ op: "set", path: [key], value });
const inc = (key: string, by = 1) => ({ op: "increment", path: [key], by });

test("a change shows at once, and settles when the server accepts it", async () => {
  const server = new FakeServer({ title: "Untitled" });
  const ada = server.connect("ada");

  const made = ada.change([set("title", "Plan")]);
  assert.equal(made.ok, true);
  assert.deepEqual(ada.state, { title: "Plan" });
  assert.equal(ada.pending.length, 1);
  assert.equal(ada.revision, 0);

  await server.settle();
  await ada.settled();
  assert.equal(ada.pending.length, 0);
  assert.equal(ada.revision, 1);
  assert.deepEqual(ada.state, server.state);
});

test("a change the engine refuses is not made", () => {
  const server = new FakeServer({ s: "text" });
  const ada = server.connect("ada");
  assert.deepEqual(ada.change([inc("s")]), { ok: false, reason: "not_a_number" });
  assert.equal(ada.pending.length, 0);
});

test("a transaction answered before its event is not sent again", async () => {
  const server = new FakeServer();
  const ada = server.connect("ada");
  ada.change([inc("n")]);
  ada.change([inc("n")]);

  // Replies only, no events yet: the first is answered, then the second is sent.
  for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(server.sends, ["ada-1", "ada-2"]);
  assert.deepEqual(ada.state, { n: 2 });

  server.deliver();
  assert.equal(ada.pending.length, 0);
  assert.deepEqual(ada.state, { n: 2 });
});

test("others' changes land under this browser's pending ones", async () => {
  const server = new FakeServer({ a: 0, b: 0 });
  const ada = server.connect("ada");
  const ken = server.connect("ken");

  ken.change([set("a", 1)]);
  await server.settle();

  ada.setOnline(false);
  ada.change([set("b", 2)]);
  assert.deepEqual(ada.state, { a: 1, b: 2 });

  ken.change([inc("a", 10)]);
  await server.settle();
  // Ada's change waits (she is offline), over Ken's.
  assert.deepEqual(ada.state, { a: 11, b: 2 });
  assert.equal(ada.pending.length, 1);

  ada.setOnline(true);
  await server.settle();
  assert.equal(ada.pending.length, 0);
  assert.deepEqual(ken.state, { a: 11, b: 2 });
});

test("a refused transaction leaves the queue and the view", async () => {
  const server = new FakeServer({ n: 1 });
  const ada = server.connect("ada");
  const ken = server.connect("ken");
  const refused: string[] = [];
  ada.on((event) => {
    if (event.type === "refused") refused.push(event.reason);
  });

  // Ken makes n a string; Ada's increment, made before she saw it, is refused.
  ken.change([set("n", "text")]);
  ada.change([inc("n")]);
  await server.settle();

  assert.deepEqual(refused, ["not_a_number"]);
  assert.equal(ada.pending.length, 0);
  assert.deepEqual(ada.state, { n: "text" });
  assert.deepEqual(ken.state, { n: "text" });
});

test("offline, changes wait; the reconnect sends only those the server does not have", async () => {
  const server = new FakeServer();
  const ada = server.connect("ada");

  ada.change([inc("n")]);
  await server.settle();
  assert.equal(ada.revision, 1);

  // The second is accepted, but the reply and event are lost.
  ada.change([inc("n")]);
  await Promise.resolve();
  server.browsers[0].inbox.length = 0;
  ada.setOnline(false);
  ada.change([inc("n", 5)]);
  assert.deepEqual(ada.state, { n: 7 });

  // Reconnect: the room opens the document again with the pending ids.
  await new Promise((resolve) => setImmediate(resolve));
  const accepted = ada.pending.map((tx) => tx.id).filter((id) => server.receipts.has(id));
  ada.setOnline(true);
  ada.reset(server.snapshot(accepted));
  await server.settle();

  assert.deepEqual(server.state, { n: 7 });
  assert.deepEqual(ada.state, { n: 7 });
  assert.equal(ada.pending.length, 0);
});

test("a gap or another epoch puts the copy out of step", () => {
  const server = new FakeServer();
  const ada = server.connect("ada");
  const reasons: string[] = [];
  ada.on((event) => {
    if (event.type === "out_of_step") reasons.push(event.reason);
  });

  ada.receive({ id: "x", epoch: "e1", base_revision: 0, revision: 2, author: "ken", ops: [inc("n")] });
  ada.receive({ id: "y", epoch: "e2", base_revision: 0, revision: 1, author: "ken", ops: [inc("n")] });
  assert.deepEqual(reasons, ["gap", "epoch"]);
  assert.equal(ada.revision, 0);
});

test("a reset to a new epoch refuses the pending transactions of the old one", () => {
  const server = new FakeServer();
  const ada = server.connect("ada");
  server.online = false;
  ada.setOnline(false);
  ada.change([inc("n")]);

  const refused: string[] = [];
  ada.on((event) => {
    if (event.type === "refused") refused.push(event.transaction.id);
  });

  ada.reset({ ...server.snapshot(), epoch: "e2", state: { fresh: true } });
  assert.deepEqual(refused, ["ada-1"]);
  assert.deepEqual(ada.state, { fresh: true });
});

test("browsers that change at once converge on the server's state", async () => {
  // A seeded generator: the same interleavings on every run.
  let seed = 7;
  const random = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);

  for (let round = 0; round < 30; round++) {
    const server = new FakeServer();
    const docs = ["ada", "ken", "mei"].map((name) => server.connect(name));

    for (let step = 0; step < 40; step++) {
      const doc = docs[Math.floor(random() * docs.length)];
      const key = ["a", "b", "c"][Math.floor(random() * 3)];
      const roll = random();
      if (roll < 0.4) doc.change([inc(key, 1 + Math.floor(random() * 3))]);
      else if (roll < 0.7) doc.change([set(key, Math.floor(random() * 10))]);
      else if (roll < 0.8) doc.change([{ op: "delete", path: [key] }]);
      // Deliver some events, at random moments.
      if (random() < 0.3) server.deliver();
      await new Promise((resolve) => setImmediate(resolve));
    }

    await server.settle();
    for (const doc of docs) {
      assert.equal(doc.pending.length, 0);
      assert.deepEqual(doc.state, server.state, `round ${round}`);
      assert.equal(doc.revision, server.revision);
    }
  }
});
