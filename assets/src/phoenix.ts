// A room's transport on a Phoenix channel: topic "issho:" <> room, on a
// socket the rooms of the page share (sockets.ts).
//
// The join carries the token the LiveView signed. Phoenix joins again by
// itself after a drop, reading the token afresh; a token that expired is
// renewed through `renew` (the LiveView signs a new one), and renewed ahead
// of time every `renewEvery` milliseconds while the room is open.
//
// The room is offline as soon as there is reason to think so: the
// browser's offline event, or a push with no reply (the lease then checks
// the socket, and the room joins again on a fresh channel or socket).

import type { Channel } from "phoenix";
import { Refused } from "./document";
import type { RoomTransport } from "./room";
import { lease, type Lease } from "./sockets";

export interface PhoenixTransportOptions {
  /** The socket's path or URL ("/issho/socket"). */
  socket?: string;
  /** The current join token. */
  token: string;
  /** Asks the server for a new token (through the LiveView). */
  renew?: () => Promise<string>;
  /** Milliseconds between renewals while the room is open (180000). */
  renewEvery?: number;
  /** The socket's `max_channels_per_transport` (100). */
  maxChannels?: number;
  /** Milliseconds a push waits for its reply (10000). */
  timeout?: number;
}

export function phoenixTransport(room: string, options: PhoenixTransportOptions): RoomTransport {
  const topic = `issho:${room}`;
  const timeout = options.timeout ?? 10_000;
  let token = options.token;
  let channel: Channel;
  let current: Lease;
  let renewTimer: ReturnType<typeof setInterval> | undefined;
  const offline = (): void => status("closed");
  let joined = false;
  const handlers: [string, (payload: never) => void][] = [];
  const statusCallbacks: ((status: "joined" | "closed") => void)[] = [];
  const status = (value: "joined" | "closed"): void => statusCallbacks.forEach((callback) => callback(value));

  const renew = async (): Promise<void> => {
    if (!options.renew) return;
    try {
      token = await options.renew();
    } catch {
      // The next renewal, or the next join, tries again.
    }
  };

  const open = (): Promise<{ session: string; can: "read" | "write" }> =>
    new Promise((resolve, reject) => {
      channel = current.socket.channel(topic, () => ({ token }));
      for (const [event, callback] of handlers) channel.on(event, callback as (payload: unknown) => void);
      channel.onError(() => status("closed"));
      channel.onClose(() => status("closed"));

      let first = true;
      channel
        .join(timeout)
        .receive("ok", (reply: { session: string; can: "read" | "write" }) => {
          joined = true;
          if (first) {
            first = false;
            resolve(reply);
          } else {
            status("joined");
          }
        })
        .receive("error", ({ reason }: { reason?: string }) => {
          // Phoenix joins again shortly: an expired token is renewed first, and
          // a full socket takes the join once the server lets a channel go.
          if (reason === "expired") void renew();
          else if (reason === "too many channels joined") status("closed");
          else if (first && !joined) {
            first = false;
            channel.leave();
            clearInterval(renewTimer);
            window.removeEventListener("offline", offline);
            current.release();
            reject(new Refused(reason ?? "forbidden"));
          }
        })
        .receive("timeout", () => status("closed"));
    });

  return {
    join() {
      current = lease(options.socket ?? "/issho/socket", topic, options.maxChannels ?? 100, () => {
        // The socket was dead: rejoin on a fresh channel.
        channel.leave();
        void open().then(() => status("joined"));
      });
      if (options.renew) renewTimer = setInterval(() => void renew(), options.renewEvery ?? 180_000);
      window.addEventListener("offline", offline);
      return open();
    },

    push(event, payload) {
      return new Promise((resolve, reject) => {
        channel
          .push(event, payload as object, timeout)
          .receive("ok", resolve)
          .receive("error", ({ reason }: { reason?: string }) => reject(new Refused(reason ?? "error")))
          .receive("timeout", () => {
            status("closed");
            current.check();
            reject(new Error("timeout"));
          });
      });
    },

    on(event, callback) {
      handlers.push([event, callback]);
      channel?.on(event, callback as (payload: unknown) => void);
    },

    onStatus(callback) {
      statusCallbacks.push(callback);
    },

    leave() {
      clearInterval(renewTimer);
      window.removeEventListener("offline", offline);
      channel?.leave();
      current?.release();
    },
  };
}
