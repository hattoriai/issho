// A room's grant, as the LiveView signs it (Issho.Live.grant/4), and its
// renewal: the hook's LiveView signs a new one if the policy still lets the
// actor in.

export interface Grant {
  room: string;
  token: string;
  can: "read" | "write";
  /** The actor's key. */
  self: string;
  socket: string;
  max_channels: number;
}

/** What a LiveView hook has to push an event and read its reply. */
export interface LiveHook {
  pushEvent(event: string, payload: object, reply: (reply: unknown) => void): unknown;
}

/** Asks the hook's LiveView for a new grant for the room; rejects when it gives none. */
export function requestGrant(hook: LiveHook, room: string, timeout = 10_000): Promise<Grant> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Issho: the LiveView did not renew the grant")), timeout);
    hook.pushEvent("issho:grant", { room }, (reply) => {
      clearTimeout(timer);
      const grant = reply as Partial<Grant> | null;
      if (grant && grant.room === room && typeof grant.token === "string") resolve(grant as Grant);
      else reject(new Error("Issho: no grant for this room"));
    });
  });
}
