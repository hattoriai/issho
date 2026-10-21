// Following someone: what you see goes where they are. It is a room's: on
// a page whose blocks share one room (an Issho page, with its people list
// and pointers), following someone follows them across all its blocks and
// the page scrolls to them; a block alone in its room (an editor on a plain
// page) follows them within itself. Blocks of other rooms are not moved.
//
// The state is the page's, in the DOM, so that a block follows with or
// without Issho's script on the page, and every block of a room agrees:
//
//   * `document.documentElement.dataset.isshoFollowing`: a JSON object of
//     room to the key of the one followed there;
//   * the `issho:following` event on `document`, `{ room, key }`, when it
//     changes (key `null`: stopped).
//
// A block follows someone, or stops, by writing it and sending the event:
// `follow(room, key)` here, or the same few lines in the block's own script.
// It stops when its person goes their own way in it (scrolls, clicks,
// types); a control that follows or stops carries `data-issho-follow-control`,
// so that pressing it is not taken for the person's own way.
//
// Issho keeps it across a reload of the tab (its session storage) and, on an
// Issho page, keeps the one followed on the screen.

const STORAGE = "issho:following";

type Following = Record<string, string>;

function all(): Following {
  if (typeof document === "undefined") return {};
  try {
    const value = JSON.parse(document.documentElement.dataset.isshoFollowing ?? "{}") as unknown;
    return typeof value === "object" && value !== null ? (value as Following) : {};
  } catch {
    return {};
  }
}

/** The key of the one followed in a room, or `null`. */
export function following(room: string): string | null {
  return all()[room] ?? null;
}

/** Follows someone in a room, by their key, or stops (`null`). */
export function follow(room: string, key: string | null): void {
  if (following(room) === key) return;
  const next = all();
  if (key) next[room] = key;
  else delete next[room];
  const root = document.documentElement;
  if (Object.keys(next).length > 0) root.dataset.isshoFollowing = JSON.stringify(next);
  else delete root.dataset.isshoFollowing;
  document.dispatchEvent(new CustomEvent("issho:following", { detail: { room, key } }));
}

/** Calls `listener` when someone else is followed in a room, or no one. Gives a function that stops it. */
export function onFollow(room: string, listener: (key: string | null) => void): () => void {
  const handler = (event: Event): void => {
    const detail = (event as CustomEvent<{ room?: string; key?: string | null }>).detail;
    if (detail?.room === room) listener(detail.key ?? null);
  };
  document.addEventListener("issho:following", handler);
  return () => document.removeEventListener("issho:following", handler);
}

/**
 * Stops following in a room when the person goes their own way in an
 * element (the page, a block): scrolls, presses, or types. Gives a function
 * that stops it.
 */
export function stopOnOwnWay(room: string, element: Document | HTMLElement = document): () => void {
  const stop = (event: Event): void => {
    if (!following(room) || !event.isTrusted) return;
    if (event instanceof KeyboardEvent && ["Shift", "Control", "Alt", "Meta", "Tab"].includes(event.key)) return;
    if ((event.target as Element | null)?.closest?.("[data-issho-follow-control]")) return;
    follow(room, null);
  };
  const types = ["wheel", "touchmove", "pointerdown", "keydown"] as const;
  for (const type of types) element.addEventListener(type, stop, { passive: true, capture: true });
  return () => {
    for (const type of types) element.removeEventListener(type, stop, { capture: true });
  };
}

// Kept across a reload of the tab.
if (typeof document !== "undefined") {
  try {
    if (!document.documentElement.dataset.isshoFollowing) {
      const kept = sessionStorage.getItem(STORAGE);
      if (kept) document.documentElement.dataset.isshoFollowing = kept;
    }
    document.addEventListener("issho:following", () => {
      const value = document.documentElement.dataset.isshoFollowing;
      if (value) sessionStorage.setItem(STORAGE, value);
      else sessionStorage.removeItem(STORAGE);
    });
  } catch {
    // A browser that keeps nothing follows within the page only.
  }
}
