// A room, as one browser is in it: one connection (whatever the transport),
// its people, its awareness, and the documents of the room this browser has
// open. Every component of a page that shares the room shares this object.

import { Awareness, type AwarenessOptions, type AwarenessState, type Frame } from "./awareness";
import {
  Refused,
  SharedDocument,
  type AcceptedTransaction,
  type DocumentLink,
  type Receipt,
  type Snapshot,
  type Transaction,
} from "./document";
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
  awareness?: AwarenessOptions;
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
   * once for every component that asks.
   */
  open(documentId: string): Promise<SharedDocument> {
    const open = this.documents.get(documentId);
    if (open) return Promise.resolve(open);
    const opening = this.opening.get(documentId);
    if (opening) return opening;

    const promise = (async () => {
      const snapshot = (await this.transport.push("open", { doc: documentId, pending: [] })) as Snapshot;
      const link: DocumentLink = {
        send: (doc, transaction) => this.transport.push("tx", { doc, tx: transaction }) as Promise<Receipt>,
      };
      const document = new SharedDocument(snapshot, link, { author: this.options.self });
      document.on((event) => {
        if (event.type === "out_of_step") void this.reopen(document);
      });
      this.documents.set(documentId, document);
      return document;
    })();

    this.opening.set(documentId, promise);
    return promise.finally(() => this.opening.delete(documentId));
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
