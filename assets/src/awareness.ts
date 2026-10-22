// Where the others in a room are, and where this browser is: places,
// selections, drags and locks.
//
// This browser's state is merged from `set` calls and sent at most every
// `interval` milliseconds, latest wins: a pointer that moves sixty times a
// second sends about twenty states. The others' states arrive in frames,
// one per node of the cluster every 50 ms; a full frame replaces what a
// node said before, and a node that has said nothing for a while is gone.

import type { Json } from "./engine";

export type AwarenessState = { [key: string]: Json };

/**
 * A component's own keys in a state: what it set under its document in
 * `blocks` (an empty object for none). Issho owns a state's top-level keys
 * (`place`, `locks`, `status`, `pointer`, `view`, `motion`, `path`,
 * `blocks`); a component keeps its own under its document.
 */
export function blockOf(state: AwarenessState | null | undefined, doc: string): AwarenessState {
  const blocks = state?.blocks;
  if (typeof blocks !== "object" || blocks === null || Array.isArray(blocks)) return {};
  const own = (blocks as AwarenessState)[doc];
  return typeof own === "object" && own !== null && !Array.isArray(own) ? (own as AwarenessState) : {};
}

/** A state's blocks with a component's keys merged into its own (`null` removes a key). */
export function withBlock(state: AwarenessState | null | undefined, doc: string, changes: AwarenessState): Json {
  const own: AwarenessState = { ...blockOf(state, doc) };
  for (const [key, value] of Object.entries(changes)) {
    if (value === null) delete own[key];
    else own[key] = value;
  }
  const blocks = { ...((typeof state?.blocks === "object" && state.blocks !== null && !Array.isArray(state.blocks)) ? (state.blocks as AwarenessState) : {}) };
  if (Object.keys(own).length === 0) delete blocks[doc];
  else blocks[doc] = own;
  return Object.keys(blocks).length === 0 ? null : blocks;
}

export interface Peer {
  session: string;
  key: string;
  state: AwarenessState;
}

export interface Frame {
  node: string;
  full: boolean;
  states: Record<string, { key: string; state: AwarenessState }>;
  gone: string[];
}

export interface AwarenessOptions {
  /** Milliseconds between this browser's sends, at most one each (50). */
  interval?: number;
  /** Milliseconds after which a node that sent nothing is gone (15000). */
  staleAfter?: number;
  now?: () => number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (timer: unknown) => void;
}

type Send = (state: AwarenessState | null) => Promise<unknown>;

export class Awareness {
  private local: AwarenessState | null = null;
  private dirty = false;
  private timer: unknown = null;
  private lastSent = -Infinity;
  private nodes = new Map<string, { seen: number; peers: Map<string, Peer> }>();
  // The sessions each node said were there when this browser joined (its
  // first full frame), and the nodes that have said so.
  private there = new Set<string>();
  private told = new Set<string>();
  private listeners = new Set<(peers: Peer[]) => void>();
  private readonly interval: number;
  private readonly staleAfter: number;
  private readonly now: () => number;
  private readonly setTimer: (fn: () => void, ms: number) => unknown;
  private readonly clearTimer: (timer: unknown) => void;

  constructor(private readonly send: Send, options: AwarenessOptions = {}) {
    this.interval = options.interval ?? 50;
    this.staleAfter = options.staleAfter ?? 15_000;
    this.now = options.now ?? (() => Date.now());
    this.setTimer = options.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
    this.clearTimer = options.clearTimer ?? ((timer) => clearTimeout(timer as ReturnType<typeof setTimeout>));
  }

  /** This browser's state. */
  get state(): AwarenessState | null {
    return this.local;
  }

  /** Merges keys into this browser's state (`null` for a key removes it), and sends it soon. */
  set(changes: AwarenessState): void {
    const next: AwarenessState = { ...(this.local ?? {}) };
    for (const [key, value] of Object.entries(changes)) {
      if (value === null) delete next[key];
      else next[key] = value;
    }
    this.local = next;
    this.schedule();
  }

  /** Clears this browser's state for the others. */
  clear(): void {
    this.local = null;
    this.schedule();
  }

  /** Sends the current state again, after a rejoin. */
  resend(): void {
    if (this.local) this.schedule();
  }

  on(listener: (peers: Peer[]) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** The others, from every node. */
  get peers(): Peer[] {
    const now = this.now();
    const peers: Peer[] = [];
    for (const [node, entry] of this.nodes) {
      if (now - entry.seen > this.staleAfter) {
        this.nodes.delete(node);
        continue;
      }
      peers.push(...entry.peers.values());
    }
    return peers;
  }

  /** A frame the channel pushed. */
  receive(frame: Frame): void {
    const entry = this.nodes.get(frame.node) ?? { seen: 0, peers: new Map<string, Peer>() };
    if (frame.full) entry.peers.clear();
    if (frame.full && !this.told.has(frame.node)) {
      this.told.add(frame.node);
      for (const [session, { state }] of Object.entries(frame.states)) if (state !== null) this.there.add(session);
    }
    for (const session of frame.gone) entry.peers.delete(session);
    for (const [session, { key, state }] of Object.entries(frame.states)) {
      if (state === null) entry.peers.delete(session);
      else entry.peers.set(session, { session, key, state });
    }
    entry.seen = this.now();
    this.nodes.set(frame.node, entry);
    this.emit();
  }

  /**
   * Whether a session was in the room when this browser joined it (or
   * joined it again): what it did before then is not news.
   */
  wasThere(session: string): boolean {
    return this.there.has(session);
  }

  /** Forgets every peer, after a disconnect. */
  reset(): void {
    this.nodes.clear();
    this.there.clear();
    this.told.clear();
    this.emit();
  }

  dispose(): void {
    if (this.timer !== null) this.clearTimer(this.timer);
    this.timer = null;
    this.listeners.clear();
  }

  private schedule(): void {
    this.dirty = true;
    if (this.timer !== null) return;
    const wait = Math.max(0, this.lastSent + this.interval - this.now());
    this.timer = this.setTimer(() => this.flush(), wait);
  }

  private flush(): void {
    this.timer = null;
    if (!this.dirty) return;
    this.dirty = false;
    this.lastSent = this.now();
    // A send that fails (offline) is not retried: the rejoin resends.
    this.send(this.local).catch(() => undefined);
  }

  private emit(): void {
    const peers = this.peers;
    for (const listener of this.listeners) listener(peers);
  }
}
