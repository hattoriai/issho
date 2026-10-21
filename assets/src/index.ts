// Issho in the browser: rooms, their people and awareness, and shared
// documents, for every component of a page.

import { registerEngine } from "./engine";
import { mapEngine } from "./engines/map";

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
export { requestGrant, type Grant, type LiveHook } from "./grant";
export { drawPeople, someone, describe, type Someone, type PeopleOptions } from "./people";
export { Hooks } from "./hooks";
export { joinRoom, releaseRoom } from "./page";
export { holdForm, type FormMember } from "./form";
export { PageHistory, pageHistory, type HistoryOwner } from "./history";
