// The browser's twin of a document's engine (Issho.Engine on the server):
// the same operations on the same state give the same state, so a browser
// shows its own changes before the server accepts them, and replays them
// over the changes of others.
//
// An engine is pure: no I/O, no clock, no randomness, and it never changes
// the state it is given.

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type State = { [key: string]: Json };
export type Operation = { [key: string]: Json };

export type Applied = { ok: true; state: State } | { ok: false; reason: string };

export interface Engine {
  /** The engine's name, as the server stores it: "map", "kotoba". */
  readonly name: string;
  readonly version: number;
  /** The state after a transaction's operations, all or none. */
  apply(state: State, ops: Operation[], author: string): Applied;
}

const engines = new Map<string, Engine>();

/** Makes an engine available to the documents that name it. */
export function registerEngine(engine: Engine): void {
  engines.set(engine.name, engine);
}

export function engine(name: string): Engine {
  const found = engines.get(name);
  if (!found) throw new Error(`Issho: no engine named "${name}"; register it with registerEngine()`);
  return found;
}
