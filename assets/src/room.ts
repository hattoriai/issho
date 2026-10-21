// A room, as one browser is in it: one connection (whatever the transport),
// its people, its awareness, and the documents of the room this browser has
// open. Every component of a page that shares the room shares this object.

import { Awareness, type AwarenessOptions, type AwarenessState, type Frame } from "./awareness";
import {
  Refused,
  SharedDocument,
  type AcceptedTransaction,
  type DocumentLink,
  type DocumentOptions,
  type Receipt,
  type Snapshot,
  type Transaction,
} from "./document";
import { claimSession, draftKey, draftOf, type Draft, type DraftStore, type SessionEnvironment } from "./drafts";
import { Presence } from "./presence";

/**
 * How a room reaches the server. The Phoenix channel is one transport
 * (`phoenixTransport`); a test's fake is another.
 */
export interface RoomTransport {
  /** Joins; resolves with the session id and what the token allows. */
  join(): Promise<{ session: string; can: "read" | "write" }>;
  /** Sends a message; resolves with the reply, rejects with `Refused` when the server refused it. */
  push(event: string, payload: unknown): Promise<unknown>;
  /** Messages the server pushes: "tx", "aware", "presence_state", "presence_diff", "bye". */
  on(event: string, callback: (payload: never) => void): void;
  /** The connection's state: "joined" after each (re)join, "closed" when it drops. */
  onStatus(callback: (status: "joined" | "closed") => void): void;
  leave(): void;
}

export type RoomStatus = "connecting" | "live" | "offline" | "ended";

export interface RoomOptions {
  /** This actor's key, as the server knows it. */
  self: string;
  /** The room's name, for the drafts' keys. */
  room?: string;
  awareness?: AwarenessOptions;
  /** Where pending transactions are kept across reloads; none unless given. */
  drafts?: DraftStore;
  /** For tests: the tab session's storage and locks. */
  session?: SessionEnvironment;
}

/** A draft the server can no longer take: its transactions, for the app to offer back. */
export interface StaleDraft {
  document: string;
  draft: Draft;
  reason: "epoch_mismatch";
}

export class Room {
  readonly presence: Presence;
  readonly awareness: Awareness;
  session: string | null = null;
  can: "read" | "write" = "read";
  private documents = new Map<string, SharedDocument>();
  private opening = new Map<string, Promise<SharedDocument>>();
  private statusValue: RoomStatus = "connecting";
  private statusListeners = new Set<(status: RoomStatus, reason?: string) => void>();
  private joinedOnce = false;
  private tabSession: Promise<string> | null = null;
  private writes = new Map<string, Promise<void>>();
  private draftListeners = new Set<(stale: StaleDraft) => void>();

  constructor(private readonly transport: RoomTransport, private readonly options: RoomOptions) {
    this.presence = new Presence(options.self);
    this.awareness = new Awareness((state) => this.transport.push("aware", { state }), options.awareness);

    transport.on("presence_state", (state: never) => this.presence.syncState(state));
    transport.on("presence_diff", (diff: never) => this.presence.syncDiff(diff));
    transport.on("aware", (frame: Frame) => this.awareness.receive(frame));
    transport.on("tx", ({ doc, event }: { doc: string; event: AcceptedTransaction }) =>
      this.documents.get(doc)?.receive(event),
    );
    transport.on("bye", ({ reason }: { reason: string }) => this.setStatus("ended", reason));
    transport.onStatus((status) => (status === "joined" ? void this.rejoined() : this.disconnected()));
  }

  get status(): RoomStatus {
    return this.statusValue;
  }

  onStatus(listener: (status: RoomStatus, reason?: string) => void): () => void {
    this.statusListeners.add(listener);
    return () => this.statusListeners.delete(listener);
  }

  /** Joins the room. */
  async connect(): Promise<void> {
    const { session, can } = await this.transport.join();
    this.session = session;
    this.can = can;
    this.joinedOnce = true;
    this.setStatus("live");
  }

  /**
   * Opens a document of the room (the room itself, or a path under it),
   * once for every component that asks. `batch` makes changes close
   * together one transaction (see `DocumentOptions`); the first open's
   * options hold.
   */
  open(documentId: string, options: { batch?: DocumentOptions["batch"] } = {}): Promise<SharedDocument> {
    const open = this.documents.get(documentId);
    if (open) return Promise.resolve(open);
    const opening = this.opening.get(documentId);
    if (opening) return opening;

    const promise = (async () => {
      const key = await this.draftKey(documentId);
      const draft = key ? await this.options.drafts!.load(key) : null;
      const pendingIds = draft?.pending.map((tx) => tx.id) ?? [];
      const snapshot = (await this.transport.push("open", { doc: documentId, pending: pendingIds })) as Snapshot;
      const link: DocumentLink = {
        send: (doc, transaction) => this.transport.push("tx", { doc, tx: transaction }) as Promise<Receipt>,
      };

      // A draft of another epoch can never apply: report it, keep it aside.
      let restore: Transaction[] = [];
      if (draft && key && draft.epoch !== snapshot.epoch) {
        await this.options.drafts!.save(`${key}:stale`, draft);
        for (const listener of this.draftListeners) listener({ document: documentId, draft, reason: "epoch_mismatch" });
      } else if (draft) {
        restore = draft.pending;
      }

      const document = new SharedDocument(snapshot, link, {
        author: this.options.self,
        pending: restore,
        batch: options.batch,
        persist: key ? (accepted, pending) => this.keep(key, accepted, pending) : undefined,
      });
      document.on((event) => {
        if (event.type === "out_of_step") void this.reopen(document);
      });
      this.documents.set(documentId, document);
      return document;
    })();

    this.opening.set(documentId, promise);
    return promise.finally(() => this.opening.delete(documentId));
  }

  /** Called with each draft the server could no longer take, when its document opens. */
  onStaleDraft(listener: (stale: StaleDraft) => void): () => void {
    this.draftListeners.add(listener);
    return () => this.draftListeners.delete(listener);
  }

  /** Throws away a document's stale draft, once the app has offered it back. */
  async discardStaleDraft(documentId: string): Promise<void> {
    const key = await this.draftKey(documentId);
    if (key) await this.options.drafts!.remove(`${key}:stale`);
  }

  // Writes of one draft go in order; an empty queue leaves nothing behind.
  private keep(key: string, accepted: Snapshot, pending: Transaction[]): void {
    const store = this.options.drafts!;
    const previous = this.writes.get(key) ?? Promise.resolve();
    const next = previous
      .then(() => (pending.length > 0 ? store.save(key, draftOf(accepted, [...pending])) : store.remove(key)))
      .catch(() => undefined);
    this.writes.set(key, next);
  }

  /** Resolves when every draft write so far is done. */
  async flushDrafts(): Promise<void> {
    await Promise.all(this.writes.values());
  }

  private async draftKey(documentId: string): Promise<string | null> {
    if (!this.options.drafts) return null;
    const room = this.options.room ?? "";
    this.tabSession ??= claimSession(JSON.stringify([room, this.options.self]), this.options.session);
    const session = await this.tabSession;
    return draftKey({ room, document: documentId, actor: this.options.self, session });
  }

  /** Sets keys of this browser's awareness state: `place`, `locks`, `status`, your own. */
  aware(changes: AwarenessState): void {
    this.awareness.set(changes);
  }

  leave(): void {
    this.awareness.dispose();
    this.transport.leave();
    this.setStatus("ended", "left");
  }

  // After a reconnect: open each document again with its pending
  // transactions, so the server says which it already has.
  private async rejoined(): Promise<void> {
    if (!this.joinedOnce) return;
    this.setStatus("live");
    this.awareness.resend();
    await Promise.all([...this.documents.values()].map((document) => this.reopen(document)));
  }

  private async reopen(document: SharedDocument): Promise<void> {
    const pending = document.pending.map((tx: Transaction) => tx.id);
    try {
      const snapshot = (await this.transport.push("open", { doc: document.id, pending })) as Snapshot;
      document.reset(snapshot);
      document.setOnline(true);
    } catch (error) {
      if (error instanceof Refused) this.setStatus("ended", error.reason);
    }
  }

  private disconnected(): void {
    if (this.statusValue === "ended") return;
    for (const document of this.documents.values()) document.setOnline(false);
    this.awareness.reset();
    this.setStatus("offline");
  }

  private setStatus(status: RoomStatus, reason?: string): void {
    if (this.statusValue === "ended") return;
    this.statusValue = status;
    for (const listener of this.statusListeners) listener(status, reason);
  }
}
