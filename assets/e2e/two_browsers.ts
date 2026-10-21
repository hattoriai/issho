// Two browsers in one Node.js process, each with its own socket, on a real
// Issho endpoint (test/issho/end_to_end_test.exs starts it and signs their
// tokens). Prints what each ended with, as one line of JSON.

// What the client needs of a browser.
// Node.js 20 has no navigator; 21 and later have one without onLine.
(globalThis as unknown as { window: EventTarget }).window = new EventTarget();
if (typeof globalThis.navigator === "undefined") {
  Object.defineProperty(globalThis, "navigator", { value: { onLine: true }, configurable: true });
} else {
  Object.defineProperty(globalThis.navigator, "onLine", { value: true, configurable: true });
}

import { registerEngine, mapEngine, Room, phoenixTransport } from "../src/index";

registerEngine(mapEngine);

const { ISSHO_URL: url, ISSHO_ROOM: room, ISSHO_ADA: adaToken, ISSHO_KEN: kenToken } = process.env as Record<string, string>;
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function until(check: () => boolean, ms = 3000): Promise<void> {
  const start = Date.now();
  while (!check()) {
    if (Date.now() - start > ms) throw new Error("timed out");
    await wait(10);
  }
}

const ada = new Room(phoenixTransport(room, { socket: url, token: adaToken }), { self: "user:ada" });
const ken = new Room(phoenixTransport(room, { socket: url, token: kenToken }), { self: "user:ken" });
await Promise.all([ada.connect(), ken.connect()]);

const [adaDoc, kenDoc] = await Promise.all([ada.open(room), ken.open(room)]);

adaDoc.change([{ op: "set", path: ["title"], value: "Plan" }]);
for (let i = 0; i < 10; i++) {
  adaDoc.change([{ op: "increment", path: ["n"], by: 1 }]);
  kenDoc.change([{ op: "increment", path: ["n"], by: 1 }]);
}

await Promise.all([adaDoc.settled(), kenDoc.settled()]);
await until(() => adaDoc.revision === 21 && kenDoc.revision === 21);

ada.aware({ place: { doc: room, at: { path: ["title"] } } });
await until(() => ken.awareness.peers.some((peer) => peer.key === "user:ada"));
await until(() => ken.presence.others.some((person) => person.key === "user:ada"));

console.log(
  JSON.stringify({
    ada: adaDoc.state,
    ken: kenDoc.state,
    revisions: [adaDoc.revision, kenDoc.revision],
    kenSeesPlace: ken.awareness.peers.find((peer) => peer.key === "user:ada")?.state,
    kenSeesPeople: ken.presence.others.map((person) => person.key),
  }),
);

ada.leave();
ken.leave();
await wait(50);
process.exit(0);
