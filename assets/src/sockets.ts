import { Socket } from "phoenix";

/**
 * The rooms of a page lease a Phoenix socket per URL, each with its own
 * channel on it. A socket takes another room while it has no channel for
 * that room (Phoenix holds one channel per topic on a socket) and fewer
 * channels than the server's limit; otherwise the room gets a new socket.
 *
 * A socket belongs to its leases: it connects with the first, goes down and up
 * with the browser's offline and online events, and closes with the last
 * release. A room never disconnects it. A stuck room asks the lease to check
 * the socket: if the server answers a ping, that room alone recovers; if not,
 * the lease reconnects the socket once and every room on it recovers.
 *
 * (From Kotoba's collaboration, where it was written for its editors.)
 */
export interface Lease { readonly socket: Socket; check(): void; release(): void }

// How long a ping may go unanswered before the socket counts as dead.
const PING_TIMEOUT = 5_000;

interface Entry { socket: Socket; maxChannels: number; recovers: Map<string, () => void>; checking: Set<string> | null; close: () => void }
const entries = new Map<string, Entry[]>();

function open(url: string, maxChannels: number): Entry {
  const socket = new Socket(url);
  const offline = (): void => socket.disconnect();
  const online = (): void => socket.connect();
  window.addEventListener("offline", offline);
  window.addEventListener("online", online);
  if (navigator.onLine) socket.connect();
  const entry: Entry = { socket, maxChannels, recovers: new Map(), checking: null, close: () => { window.removeEventListener("offline", offline); window.removeEventListener("online", online); socket.disconnect(); } };
  // A check is about the connection it pinged: once that connection goes, Phoenix joins the channels again.
  socket.onOpen(() => { entry.checking = null; });
  socket.onClose(() => { entry.checking = null; });
  return entry;
}

function check(entry: Entry, topic: string): void {
  if (entry.checking) { entry.checking.add(topic); return; }
  const checking = new Set([topic]);
  const pinged = entry.socket.ping(() => {
    if (entry.checking !== checking) return;
    entry.checking = null;
    checking.forEach(waiting => entry.recovers.get(waiting)?.());
  });
  // Not connected: the socket reconnects by itself and Phoenix joins its channels again.
  if (!pinged) return;
  entry.checking = checking;
  setTimeout(() => {
    if (entry.checking !== checking) return;
    entry.checking = null;
    if (entry.recovers.size === 0) return;
    // Phoenix doesn't learn that a dead connection's channels are gone, so every room joins again.
    entry.socket.disconnect(() => {
      if (entry.recovers.size === 0) return;
      // Offline meanwhile: the joins wait for the browser's online event to connect the socket.
      if (navigator.onLine) entry.socket.connect();
      entry.recovers.forEach(recover => recover());
    });
  }, PING_TIMEOUT);
}

export function lease(url: string, topic: string, maxChannels: number, recover: () => void): Lease {
  const sockets = entries.get(url) ?? [];
  entries.set(url, sockets);
  let entry = sockets.find(candidate => !candidate.recovers.has(topic) && candidate.recovers.size < Math.min(candidate.maxChannels, maxChannels));
  if (!entry) { entry = open(url, maxChannels); sockets.push(entry); }
  const current = entry;
  current.recovers.set(topic, recover);
  let released = false;
  return {
    socket: current.socket,
    check: () => { if (!released) check(current, topic); },
    release: () => {
      if (released) return;
      released = true;
      current.recovers.delete(topic);
      current.checking?.delete(topic);
      if (current.recovers.size > 0) return;
      current.close();
      sockets.splice(sockets.indexOf(current), 1);
      if (sockets.length === 0) entries.delete(url);
    },
  };
}
