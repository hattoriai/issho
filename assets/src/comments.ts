// The marks of a room's threads of comments on the page: one at each
// thread's place, where its component locates it (`locate`), as the
// pointers are. Issho.Components.comments/1 renders the threads; its hook
// (IsshoComments) draws their marks with this.

import { locatePlace, type Box } from "./pointers";

/** A thread the page marks: where it is, and what its mark says. */
export interface Marked {
  id: string;
  place: { doc: string; at?: unknown; label?: string };
  /** Its comments, the number on the mark. */
  count: number;
  /** What a screen reader says of it: "3 comments, Ada: Should this go first?". */
  label: string;
  /** The colour of whoever began it. */
  color?: string | null;
  palette?: number;
}

export interface MarkersOptions {
  /** A mark clicked, or chosen from the keyboard. */
  open: (thread: string) => void;
  /** Where a place is on this page; `locatePlace` unless given (tests). */
  locate?: (doc: string, at?: unknown) => Box | null;
}

/**
 * Where a thread's mark goes for its place's box: at the box's top right
 * corner, in the viewport; `null` when the box is not on the screen.
 */
export function markSpot(box: Box, viewport: { width: number; height: number }, size = 24): { x: number; y: number } | null {
  if (box.top + box.height < 0 || box.top > viewport.height || box.left + box.width < 0 || box.left > viewport.width) return null;
  const x = Math.min(Math.max(box.left + box.width - size / 2, 0), viewport.width - size);
  const y = Math.min(Math.max(box.top - size / 2, 0), viewport.height - size);
  return { x, y };
}

/**
 * A layer of marks over the page, one for each thread with a place on it.
 * `draw` takes the threads; it follows the page as it scrolls and as the
 * components' content moves under the marks.
 */
export function commentMarkers(options: MarkersOptions): { draw: (threads: Marked[], focused?: string | null) => void; stop: () => void } {
  const locate = options.locate ?? locatePlace;
  const layer = document.createElement("div");
  layer.className = "issho-comment-marks";
  document.body.appendChild(layer);
  const marks = new Map<string, HTMLButtonElement>();
  let threads: Marked[] = [];
  let focused: string | null = null;
  let frame = 0;
  let moving = 0;

  const render = (): void => {
    const viewport = { width: window.innerWidth, height: window.innerHeight };
    const wanted = new Set(threads.map((thread) => thread.id));
    for (const [id, mark] of marks) {
      if (!wanted.has(id)) {
        mark.remove();
        marks.delete(id);
      }
    }
    for (const thread of threads) {
      let mark = marks.get(thread.id);
      if (!mark) {
        mark = document.createElement("button");
        mark.type = "button";
        mark.className = "issho-comment-mark";
        mark.dataset.thread = thread.id;
        mark.addEventListener("click", () => options.open(thread.id));
        layer.appendChild(mark);
        marks.set(thread.id, mark);
      }
      mark.textContent = String(thread.count);
      mark.setAttribute("aria-label", thread.label);
      mark.title = thread.label;
      mark.style.setProperty("--issho-color", thread.color ?? `var(--issho-person-${thread.palette ?? 1})`);
      if (thread.id === focused) mark.dataset.focused = "";
      else delete mark.dataset.focused;
      const box = locate(thread.place.doc, thread.place.at);
      const spot = box ? markSpot(box, viewport) : null;
      if (spot) {
        mark.hidden = false;
        mark.style.transform = `translate(${Math.round(spot.x)}px, ${Math.round(spot.y)}px)`;
      } else {
        mark.hidden = true;
      }
    }
  };

  const schedule = (): void => {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      render();
    });
  };

  window.addEventListener("scroll", schedule, { passive: true, capture: true });
  window.addEventListener("resize", schedule);

  return {
    draw(next: Marked[], focus: string | null = null): void {
      threads = next;
      focused = focus;
      render();
      // A component's content moves under its marks (text typed before a
      // range, a node dragged): looked at again while there are marks.
      if (threads.length > 0 && !moving) moving = window.setInterval(schedule, 400);
      if (threads.length === 0 && moving) {
        clearInterval(moving);
        moving = 0;
      }
    },
    stop(): void {
      window.removeEventListener("scroll", schedule, { capture: true });
      window.removeEventListener("resize", schedule);
      if (frame) cancelAnimationFrame(frame);
      if (moving) clearInterval(moving);
      layer.remove();
    },
  };
}
