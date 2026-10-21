// This browser's pending transactions, kept so that a reload, a crash or a
// closed laptop loses nothing: each tab keeps its own, under a session that
// survives a reload of that tab, and the room sends them when it opens the
// document again.
//
// A draft the server can no longer take (the document's epoch changed: it
// was replaced or migrated) is never thrown away by Issho: the room reports
// it, and keeps it until the app discards it.

import type { Snapshot, Transaction } from "./document";

export interface Draft {
  epoch: string;
  revision: number;
  pending: Transaction[];
}

/** Where drafts are kept: IndexedDB in a browser, memory in a test. */
export interface DraftStore {
  load(key: string): Promise<Draft | null>;
  save(key: string, draft: Draft): Promise<void>;
  remove(key: string): Promise<void>;
}

export class MemoryDraftStore implements DraftStore {
  readonly drafts = new Map<string, Draft>();
  async load(key: string): Promise<Draft | null> {
    const draft = this.drafts.get(key);
    return draft ? structuredClone(draft) : null;
  }
  async save(key: string, draft: Draft): Promise<void> {
    this.drafts.set(key, structuredClone(draft));
  }
  async remove(key: string): Promise<void> {
    this.drafts.delete(key);
  }
}

export class IndexedDraftStore implements DraftStore {
  private database: Promise<IDBDatabase> | null = null;

  private open(): Promise<IDBDatabase> {
    this.database ??= new Promise((resolve, reject) => {
      const request = indexedDB.open("issho-v1", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("drafts");
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
      request.onblocked = () => reject(new Error("Issho: the drafts database is blocked"));
    });
    return this.database;
  }

  private async run<T>(mode: IDBTransactionMode, action: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
    const database = await this.open();
    return new Promise((resolve, reject) => {
      const transaction = database.transaction("drafts", mode);
      const request = action(transaction.objectStore("drafts"));
      transaction.oncomplete = () => resolve(request.result);
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error);
    });
  }

  async load(key: string): Promise<Draft | null> {
    return ((await this.run("readonly", (store) => store.get(key))) as Draft | undefined) ?? null;
  }

  async save(key: string, draft: Draft): Promise<void> {
    await this.run("readwrite", (store) => store.put(draft, key));
  }

  async remove(key: string): Promise<void> {
    await this.run("readwrite", (store) => store.delete(key));
  }
}

/** IndexedDB when the browser has it and allows it, else memory (drafts last only while the tab is open). */
export function defaultDraftStore(): { store: DraftStore; durable: boolean } {
  try {
    if (typeof indexedDB !== "undefined") return { store: new IndexedDraftStore(), durable: true };
  } catch {
    // Storage can be disabled.
  }
  return { store: new MemoryDraftStore(), durable: false };
}

export interface SessionEnvironment {
  storage?: Pick<Storage, "getItem" | "setItem"> | null;
  locks?: Pick<LockManager, "request"> | null;
  newId?: () => string;
}

/**
 * The tab's session for a scope: the same after a reload of the tab, and a
 * new one for a tab that copied it (a duplicated tab copies sessionStorage):
 * a Web Lock held for the tab's life tells them apart.
 */
export async function claimSession(scope: string, env: SessionEnvironment = browserEnvironment()): Promise<string> {
  const key = `issho:session:${scope}`;
  const newId = env.newId ?? (() => crypto.randomUUID());
  let session: string = newId();
  try {
    session = env.storage?.getItem(key) ?? session;
    env.storage?.setItem(key, session);
  } catch {
    // Storage can be disabled.
  }
  if (!env.locks) return session;

  for (;;) {
    const claimed = await new Promise<boolean>((resolve) => {
      void env.locks!.request(`issho:${scope}:${session}`, { ifAvailable: true }, (lock) => {
        if (!lock) {
          resolve(false);
          return undefined;
        }
        resolve(true);
        // Held until the tab goes away.
        return new Promise<void>(() => undefined);
      });
    });
    if (claimed) break;
    session = newId();
    try {
      env.storage?.setItem(key, session);
    } catch {
      // Storage can be disabled.
    }
  }
  return session;
}

function browserEnvironment(): SessionEnvironment {
  let storage: Storage | null = null;
  try {
    storage = typeof sessionStorage === "undefined" ? null : sessionStorage;
  } catch {
    storage = null;
  }
  const locks = typeof navigator !== "undefined" && "locks" in navigator ? navigator.locks : null;
  return { storage, locks };
}

/** The key of a document's draft: origin, room, document, actor and tab session. */
export function draftKey(parts: { room: string; document: string; actor: string; session: string }): string {
  const origin = typeof location === "undefined" ? "" : location.origin;
  return JSON.stringify([origin, parts.room, parts.document, parts.actor, parts.session]);
}

export function draftOf(snapshot: Snapshot, pending: Transaction[]): Draft {
  return { epoch: snapshot.epoch, revision: snapshot.revision, pending };
}
