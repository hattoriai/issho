// A document of a room, as one browser holds it: the state the server
// accepted, the transactions of this browser it has not accepted yet, and
// the view people see, which is the second replayed over the first.
//
// A change shows at once. Transactions go to the server one at a time, in
// the order they were made, and never change once made: a resend after a
// lost reply or a reconnect is the same transaction, which the server
// applies once. The server's transactions arrive in revision order; each
// is applied to the accepted state, and the pending ones are replayed over
// it. A gap in the revisions, another epoch, or a transaction the engine
// cannot apply means this copy is out of step: the room opens the
// document again (`reset`).

import { engine as engineNamed, type Engine, type Operation, type State } from "./engine";

export interface Transaction {
  id: string;
  epoch: string;
  base_revision: number;
  ops: Operation[];
}

export interface AcceptedTransaction extends Transaction {
  revision: number;
  author: string;
}

export interface Snapshot {
  id: string;
  engine: string;
  epoch: string;
  revision: number;
  state: State;
  accepted?: string[];
}

export interface Receipt {
  id: string;
  revision: number;
  duplicate?: boolean;
}

/** How a document reaches its authority: a room's channel, or a test's fake. */
export interface DocumentLink {
  send(documentId: string, transaction: Transaction): Promise<Receipt>;
}

/** Thrown by a link when the server refused a transaction (not when the connection failed). */
export class Refused extends Error {
  constructor(readonly reason: string) {
    super(`Issho: the server refused the transaction (${reason})`);
  }
}

export type DocumentEvent =
  | { type: "change"; state: State; origin: "local" | "remote" | "reset" }
  | { type: "refused"; transaction: Transaction; reason: string }
  | { type: "out_of_step"; reason: string }
  | { type: "settled" };

export interface DocumentOptions {
  /** The actor's key, given to the engine for local changes. */
  author: string;
  /** A new id for each transaction. */
  newId?: () => string;
  /** Called after every change of the pending queue, to keep it (an offline store). */
  persist?: (snapshot: Snapshot, pending: Transaction[]) => void;
  /**
   * Pending transactions kept from before (a draft), of the snapshot's
   * epoch: those the snapshot's `accepted` does not name are replayed and
   * sent.
   */
  pending?: Transaction[];
}

export class SharedDocument {
  readonly id: string;
  private readonly engine: Engine;
  private accepted: Snapshot;
  private queue: Transaction[] = [];
  private view: State;
  private sending: string | null = null;
  // Transactions the server answered whose event has not arrived yet: the
  // reply usually comes first. They are not sent again.
  private acked = new Set<string>();
  private online = true;
  private listeners = new Set<(event: DocumentEvent) => void>();
  private settledWaiters: (() => void)[] = [];

  constructor(snapshot: Snapshot, private readonly link: DocumentLink, private readonly options: DocumentOptions) {
    this.id = snapshot.id;
    this.engine = engineNamed(snapshot.engine);
    this.accepted = { ...snapshot };
    this.view = snapshot.state;

    if (options.pending && options.pending.length > 0) {
      const accepted = new Set(snapshot.accepted ?? []);
      this.queue = options.pending.filter((tx) => tx.epoch === snapshot.epoch && !accepted.has(tx.id));
      this.replay();
      queueMicrotask(() => this.pump());
    }
  }

  /** The state people see: the accepted state with this browser's pending changes. */
  get state(): State {
    return this.view;
  }

  /** The revision of the accepted state. */
  get revision(): number {
    return this.accepted.revision;
  }

  get epoch(): string {
    return this.accepted.epoch;
  }

  /** This browser's transactions the server has not accepted yet. */
  get pending(): readonly Transaction[] {
    return this.queue;
  }

  on(listener: (event: DocumentEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /**
   * Makes a change: applies it to the view now, and sends it. Gives the
   * transaction, or the engine's reason when the operations do not apply.
   */
  change(ops: Operation[]): { ok: true; transaction: Transaction } | { ok: false; reason: string } {
    const applied = this.engine.apply(this.view, ops, this.options.author);
    if (!applied.ok) return applied;

    const transaction: Transaction = {
      id: (this.options.newId ?? newId)(),
      epoch: this.accepted.epoch,
      base_revision: this.accepted.revision,
      ops,
    };

    this.queue.push(transaction);
    this.view = applied.state;
    this.persist();
    this.emit({ type: "change", state: this.view, origin: "local" });
    this.pump();
    return { ok: true, transaction };
  }

  /** A transaction the server accepted, pushed to every browser with the document open. */
  receive(event: AcceptedTransaction): void {
    if (event.epoch !== this.accepted.epoch) return this.outOfStep("epoch");
    if (event.revision <= this.accepted.revision) return; // already have it
    if (event.revision !== this.accepted.revision + 1) return this.outOfStep("gap");

    const applied = this.engine.apply(this.accepted.state, event.ops, event.author);
    if (!applied.ok) return this.outOfStep(`engine: ${applied.reason}`);

    this.accepted = { ...this.accepted, state: applied.state, revision: event.revision };
    const own = this.queue.findIndex((tx) => tx.id === event.id);
    if (own >= 0) this.queue.splice(own, 1);
    this.acked.delete(event.id);
    if (this.sending === event.id) this.sending = null;

    this.replay();
    this.persist();
    this.emit({ type: "change", state: this.view, origin: own >= 0 ? "local" : "remote" });
    this.pump();
  }

  /**
   * The document as the server has it now, after a reconnect or when this
   * copy was out of step. `accepted` names pending transactions the server
   * already has; the others are sent again, unchanged.
   */
  reset(snapshot: Snapshot): void {
    const accepted = new Set(snapshot.accepted ?? []);
    const epochChanged = snapshot.epoch !== this.accepted.epoch;
    this.accepted = { ...snapshot };
    this.sending = null;
    this.acked.clear();

    // Transactions of another epoch can never apply: they are refused here.
    const stale = epochChanged ? this.queue : [];
    this.queue = epochChanged ? [] : this.queue.filter((tx) => !accepted.has(tx.id));
    for (const transaction of stale) this.emit({ type: "refused", transaction, reason: "epoch_mismatch" });

    this.replay();
    this.persist();
    this.emit({ type: "change", state: this.view, origin: "reset" });
    this.pump();
  }

  /** Whether the link can send; offline, transactions wait in the queue. */
  setOnline(online: boolean): void {
    this.online = online;
    if (!online) this.sending = null;
    this.pump();
  }

  /** Resolves when every pending transaction has been accepted. */
  settled(): Promise<void> {
    if (this.queue.length === 0) return Promise.resolve();
    return new Promise((resolve) => this.settledWaiters.push(resolve));
  }

  // The view: the accepted state with the pending transactions replayed. A
  // transaction that no longer applies (a concurrent change took away what
  // it changed) stays out of the view; the server will refuse it too, or
  // accept it if the engine there decides otherwise.
  private replay(): void {
    let view = this.accepted.state;
    for (const tx of this.queue) {
      const applied = this.engine.apply(view, tx.ops, this.options.author);
      if (applied.ok) view = applied.state;
    }
    this.view = view;
  }

  private pump(): void {
    if (this.queue.length === 0) {
      const waiters = this.settledWaiters.splice(0);
      if (waiters.length > 0) this.emit({ type: "settled" });
      for (const resolve of waiters) resolve();
      return;
    }
    if (!this.online || this.sending) return;

    const transaction = this.queue.find((tx) => !this.acked.has(tx.id));
    if (!transaction) return;
    this.sending = transaction.id;

    this.link.send(this.id, transaction).then(
      (receipt) => this.acknowledged(transaction, receipt),
      (error: unknown) => this.failed(transaction, error),
    );
  }

  private acknowledged(transaction: Transaction, receipt: Receipt): void {
    if (this.sending === transaction.id) this.sending = null;
    // The accepted transaction itself comes as an event, in revision order.
    // Until it does, the transaction stays in the view and is not sent
    // again; if the state already has its revision, it is done.
    const index = this.queue.findIndex((tx) => tx.id === transaction.id);
    if (index >= 0 && receipt.revision <= this.accepted.revision) {
      this.queue.splice(index, 1);
      this.replay();
      this.persist();
    } else if (index >= 0) {
      this.acked.add(transaction.id);
    }
    this.pump();
  }

  private failed(transaction: Transaction, error: unknown): void {
    if (this.sending === transaction.id) this.sending = null;

    if (error instanceof Refused) {
      this.queue = this.queue.filter((tx) => tx.id !== transaction.id);
      this.replay();
      this.persist();
      this.emit({ type: "refused", transaction, reason: error.reason });
      this.emit({ type: "change", state: this.view, origin: "reset" });
      this.pump();
    }
    // A connection failure: the transaction waits for the reconnect, whose
    // reset sends it again.
  }

  private outOfStep(reason: string): void {
    this.emit({ type: "out_of_step", reason });
  }

  private persist(): void {
    this.options.persist?.(this.accepted, this.queue);
  }

  private emit(event: DocumentEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}

function newId(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
