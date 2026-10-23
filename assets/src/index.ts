// Issho in the browser: rooms, their people and awareness, and shared
// documents, for every component of a page.

import { registerEngine } from "./engine";
import { mapEngine } from "./engines/map";
import { commentsEngine } from "./engines/comments";

registerEngine(mapEngine);
registerEngine(commentsEngine);

export { registerEngine, engine, type Engine, type State, type Operation, type Json, type Applied } from "./engine";
export { mapEngine } from "./engines/map";
export { commentsEngine, type Thread, type Comment } from "./engines/comments";
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
export { Awareness, blockOf, type AwarenessState, type Peer, type Frame } from "./awareness";
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
export {
  pointerLayer,
  pointing,
  gestureTracker,
  type Gestures,
  pointerAt,
  roomOf,
  fractions,
  place,
  locate,
  locatePlace,
  point,
  type Locator,
  type Pointer,
  type DocPointer,
  type BlockPointer,
  type Box,
  type PagePointer,
  type Pointing,
  type PointerLayerOptions,
} from "./pointers";
export { configure, type Look } from "./theme";
export { follow, following, onFollow, stopOnOwnWay } from "./follow";
export { motion, setMotion, onMotion, type Motion } from "./motion";
export { Hooks } from "./hooks";
export { commentMarkers, markSpot, type Marked, type MarkersOptions } from "./comments";
export { atWork, drawAgents, type AtWork, type Task, type TaskState, type StepState, type AgentsOptions } from "./agents";
export { joinRoom, releaseRoom } from "./page";
export { holdForm, type FormMember } from "./form";
export { PageHistory, pageHistory, type HistoryOwner } from "./history";
