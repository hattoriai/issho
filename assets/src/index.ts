// Issho in the browser: rooms, their people and awareness, and shared
// documents, for every component of a page.

import { registerEngine } from "./engine";
import { mapEngine } from "./engines/map";
import { defaultDraftStore } from "./drafts";
import { phoenixTransport, type PhoenixTransportOptions } from "./phoenix";
import { Room, type RoomOptions } from "./room";

registerEngine(mapEngine);

export { registerEngine, engine, type Engine, type State, type Operation, type Json, type Applied } from "./engine";
export { mapEngine } from "./engines/map";
export {
  SharedDocument,
  Refused,
  type Transaction,
  type AcceptedTransaction,
  type Snapshot,
  type Receipt,
  type DocumentLink,
  type DocumentEvent,
  type DocumentOptions,
} from "./document";
export { Presence, type Person, type PresenceEvent } from "./presence";
export { Awareness, type AwarenessState, type Peer, type Frame } from "./awareness";
export { Room, type RoomTransport, type RoomStatus, type RoomOptions } from "./room";
export { phoenixTransport, type PhoenixTransportOptions } from "./phoenix";
export {
  MemoryDraftStore,
  IndexedDraftStore,
  defaultDraftStore,
  claimSession,
  type Draft,
  type DraftStore,
} from "./drafts";
export type { StaleDraft } from "./room";

const rooms = new Map<string, Room>();

/**
 * The room of a page, joined once however many components ask for it.
 * `options.token` is the join token your LiveView signed
 * (`Issho.Token.sign/4`), and `options.self` the actor's key.
 */
export function joinRoom(room: string, options: PhoenixTransportOptions & RoomOptions): Promise<Room> {
  const existing = rooms.get(room);
  if (existing) return Promise.resolve(existing);

  const joined = new Room(phoenixTransport(room, options), {
    ...options,
    room,
    drafts: options.drafts ?? defaultDraftStore().store,
  });
  rooms.set(room, joined);
  joined.onStatus((status) => {
    if (status === "ended") rooms.delete(room);
  });
  return joined.connect().then(
    () => joined,
    (error: unknown) => {
      rooms.delete(room);
      throw error;
    },
  );
}
