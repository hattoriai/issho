// The rooms of a page, shared by its components.

import { defaultDraftStore } from "./drafts";
import { phoenixTransport, type PhoenixTransportOptions } from "./phoenix";
import { Room, type RoomOptions } from "./room";

// The page's rooms, joined or joining: a second component asking for a room
// gets it once it has joined. Each component that asks holds it, until it
// releases it (releaseRoom); the last to release it leaves.
const rooms = new Map<string, Promise<Room>>();
const holders = new Map<string, number>();

/**
 * The room of a page, joined once however many components ask for it.
 * `options.token` is the join token your LiveView signed
 * (`Issho.Token.sign/4`, or a grant's), and `options.self` the actor's
 * key. Release it with `releaseRoom` when the component goes.
 */
export function joinRoom(room: string, options: PhoenixTransportOptions & RoomOptions): Promise<Room> {
  holders.set(room, (holders.get(room) ?? 0) + 1);
  const existing = rooms.get(room);
  if (existing) return existing;

  const joined = new Room(phoenixTransport(room, options), {
    ...options,
    room,
    drafts: options.drafts ?? defaultDraftStore().store,
  });
  const joining = joined.connect().then(
    () => joined,
    (error: unknown) => {
      rooms.delete(room);
      holders.delete(room);
      throw error;
    },
  );
  rooms.set(room, joining);
  joined.onStatus((status) => {
    if (status === "ended" && rooms.get(room) === joining) {
      rooms.delete(room);
      holders.delete(room);
    }
  });
  return joining;
}

/** Lets go of a room a component asked for; the page leaves it when no component holds it. */
export async function releaseRoom(room: string): Promise<void> {
  const count = (holders.get(room) ?? 0) - 1;
  if (count > 0) {
    holders.set(room, count);
    return;
  }
  holders.delete(room);
  const joining = rooms.get(room);
  rooms.delete(room);
  if (joining) (await joining.catch(() => null))?.leave();
}
