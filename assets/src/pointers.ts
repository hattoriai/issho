// The page as a live space: where each person's pointer is, and their
// clicks, over any part of the page, in their colour, with their name.
//
// A pointer is never a position on the screen, because each person's page
// has its own size, scroll and layout. It is an element and a point in it,
// as fractions of its box: the nearest element with `data-issho-anchor`
// (its value), else with an id ("#id"), else the page ("page", fractions
// of the whole document). Each browser draws it where that element is on
// its own page; off the screen, at its edge, as a marker that scrolls to it.
//
// Inside an element with `data-issho-cursor="own"` (a canvas that draws its
// people's cursors itself) the page draws no pointer: the component takes
// over. Over an element with `data-issho-private`, or a password field, this
// browser shares no pointer at all, nor while its window is in the
// background. An agent has no pointer: one with a place in a document is
// drawn where that place is, when the component of the document says
// where (`locate`: the caret, a node, a cell), else at the component's top
// end (`data-issho-doc`). It glides from place to place, across the page.
//
// This browser's pointer goes into the room's awareness as `pointer`:
// `{ anchor, x, y, click? }`, `click` a number that changes with each click.

import type { Peer } from "./awareness";
import { following } from "./follow";
import { motion as motionPreference, onMotion } from "./motion";
import type { Person } from "./presence";
import { currentLook } from "./theme";

export type PagePointer = {
  anchor: string;
  x: number;
  y: number;
  click?: number;
};

/** A pointer over a component that says what is under it (`point`): a place of its document. */
export type DocPointer = {
  doc: string;
  at: unknown;
  click?: number;
};

export interface Box {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** A point in the viewport, and whether it is in it. */
export interface Spot {
  x: number;
  y: number;
  /** null in the viewport; else the edge of the viewport it is beyond. */
  edge: null | "top" | "bottom" | "left" | "right";
}

/** Someone the layer draws. */
export interface Pointing {
  key: string;
  name: string;
  color: string;
  kind: string;
  /** A pointer of the page, or the document an agent works in, and where in it. */
  pointer: PagePointer | null;
  doc: string | null;
  at?: unknown;
  /** The clicks of a pointer over a component (a place of its document), as a page pointer's. */
  click?: number;
  /** An agent's last gesture (Issho.Motion): how long its way there takes, and what it does there. */
  motion?: { gesture: string; ms: number; seq: number };
  /** An agent's place in a document, where it is drawn when the element it went to is not on this page. */
  place?: { doc: string; at: unknown };
}

/** Where a place of a document is in the viewport (its `at`), or `null`. */
export type Locator = (at: unknown) => Box | null;

/** The place of a document under a point of the viewport, or `null` (none it shares). */
export type Pointer = (clientX: number, clientY: number) => unknown;

const POINTER = Symbol.for("issho.point");
type Pointed = Element & { [POINTER]?: Pointer };

/**
 * Says what place of the document of a component is under a point of the
 * screen: the element of the component (with `data-issho-doc`), and a
 * function of the point that gives the place, in the document's terms (a
 * point of a canvas, a cell of a grid). A person's pointer over it is that
 * place, which each browser draws where it is on its own screen (`locate`):
 * the same cell in another order, the same point of a canvas panned
 * elsewhere. Gives a function that takes it back.
 */
export function point(element: Element, pointer: Pointer): () => void {
  (element as Pointed)[POINTER] = pointer;
  return () => {
    if ((element as Pointed)[POINTER] === pointer) delete (element as Pointed)[POINTER];
  };
}

// On the element itself, under a symbol of the whole page: a component
// whose bundle has a copy of this module finds the same.
const LOCATOR = Symbol.for("issho.locator");
type Located = Element & { [LOCATOR]?: Locator };

/**
 * Says where the places of the document of a component are on the page: the
 * element of the component (with `data-issho-doc`), and a function of a
 * place's `at` that gives its box in the viewport (a caret, a node, a cell).
 * An agent's pointer goes there. Gives a function that takes it back.
 */
export function locate(element: Element, locator: Locator): () => void {
  (element as Located)[LOCATOR] = locator;
  return () => {
    if ((element as Located)[LOCATOR] === locator) delete (element as Located)[LOCATOR];
  };
}

const round = (value: number): number => Math.round(value * 10_000) / 10_000;
const clamp = (value: number, min: number, max: number): number => Math.min(Math.max(value, min), max);

/** The point of a box, as fractions of it (rounded, so a state stays small). */
export function fractions(box: Box, x: number, y: number): { x: number; y: number } {
  return {
    x: box.width > 0 ? round(clamp((x - box.left) / box.width, 0, 1)) : 0,
    y: box.height > 0 ? round(clamp((y - box.top) / box.height, 0, 1)) : 0,
  };
}

/**
 * Where a pointer is in the viewport, from its anchor's box there: in it,
 * or held at its edge (`margin` inside it) with the side it is beyond.
 */
export function place(box: Box, pointer: { x: number; y: number }, viewport: { width: number; height: number }, margin = 12): Spot {
  const x = box.left + pointer.x * box.width;
  const y = box.top + pointer.y * box.height;
  let edge: Spot["edge"] = null;
  if (y < 0) edge = "top";
  else if (y > viewport.height) edge = "bottom";
  else if (x < 0) edge = "left";
  else if (x > viewport.width) edge = "right";
  if (edge === null) return { x, y, edge };
  return { x: clamp(x, margin, viewport.width - margin), y: clamp(y, margin, viewport.height - margin), edge };
}

/**
 * The others the layer draws: one each, the session that has a pointer
 * (else one with a place, for an agent), never this actor, and none whose
 * pointer is in a component that draws its own (`own`, the anchors inside
 * one).
 */
export function pointing(peers: Peer[], everyone: Person[], self: string): Pointing[] {
  const people = new Map(everyone.map((person) => [person.key, person]));
  const chosen = new Map<string, Pointing>();
  for (const peer of peers) {
    if (peer.key === self) continue;
    const motion = asMotion(peer.state.motion);
    // An agent goes where its last gesture went: an element of the page,
    // or a place of a document (where it is in that document now).
    const target = motion?.to;
    const shared = target ? null : asPointer(peer.state.pointer);
    const over = shared && "doc" in shared ? shared : null;
    const pointer = target && typeof target.anchor === "string" ? { anchor: target.anchor, x: fraction(target.x), y: fraction(target.y) } : shared && "anchor" in shared ? shared : null;
    const doc = pointer ? null : over ? over.doc : typeof target?.doc === "string" ? target.doc : docOf(peer.state.place);
    if (!pointer && !doc) continue;
    const at = !doc ? undefined : over ? over.at : docOf(peer.state.place) === doc ? atOf(peer.state.place) : target?.at;
    const person = people.get(peer.key);
    const one: Pointing = {
      key: peer.key,
      name: person?.name ?? peer.key,
      color: person?.color ?? `var(--issho-person-${person?.palette ?? 1})`,
      kind: person?.kind ?? "human",
      pointer,
      doc,
      ...(pointer ? {} : { at }),
      ...(over?.click !== undefined ? { click: over.click } : {}),
      ...(motion ? { motion: { gesture: motion.gesture, ms: motion.ms, seq: motion.seq } } : {}),
      ...(pointer && target && docOf(peer.state.place) ? { place: { doc: docOf(peer.state.place) as string, at: atOf(peer.state.place) } } : {}),
    };
    const before = chosen.get(peer.key);
    // A pointer wins over a place: the session that moved is the one with a pointer.
    if (!before || (!before.pointer && pointer)) chosen.set(peer.key, one);
  }
  return [...chosen.values()].sort((a, b) => a.name.localeCompare(b.name));
}

function asMotion(value: unknown): { to: Record<string, unknown>; gesture: string; ms: number; seq: number } | null {
  if (typeof value !== "object" || value === null) return null;
  const { to, gesture, ms, seq } = value as Record<string, unknown>;
  if (typeof to !== "object" || to === null || typeof gesture !== "string") return null;
  return { to: to as Record<string, unknown>, gesture, ms: typeof ms === "number" && ms > 0 ? Math.min(ms, 5_000) : 0, seq: typeof seq === "number" ? seq : 0 };
}

// Where in a located place's box a pointer is: the place's own `x` and `y`
// (fractions of the box, as a grid's cell says them), else its far corner
// (the end of a caret, a point).
export function within(at: unknown): { x: number; y: number } {
  const { x, y } = (typeof at === "object" && at !== null ? at : {}) as { x?: unknown; y?: unknown };
  const ok = (value: unknown): value is number => typeof value === "number" && value >= 0 && value <= 1;
  return { x: ok(x) ? x : 1, y: ok(y) ? y : 1 };
}

const fraction = (value: unknown): number => (typeof value === "number" && Number.isFinite(value) ? clamp(value, 0, 1) : 0.5);

function asPointer(value: unknown): PagePointer | DocPointer | null {
  if (typeof value !== "object" || value === null) return null;
  const { anchor, x, y, click, doc, at } = value as Record<string, unknown>;
  if (typeof doc === "string" && at !== undefined && at !== null) return { doc, at, ...(typeof click === "number" ? { click } : {}) };
  if (typeof anchor !== "string" || typeof x !== "number" || typeof y !== "number") return null;
  if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
  return { anchor, x: clamp(x, 0, 1), y: clamp(y, 0, 1), ...(typeof click === "number" ? { click } : {}) };
}

function atOf(place: unknown): unknown {
  return typeof place === "object" && place !== null ? (place as { at?: unknown }).at : undefined;
}

function docOf(place: unknown): string | null {
  if (typeof place !== "object" || place === null) return null;
  const { doc } = place as { doc?: unknown };
  return typeof doc === "string" ? doc : null;
}

// The DOM.

/** The anchor of an element: its own, or its nearest ancestor's. `null` where nothing is shared. */
export function anchorOf(target: Element | null): { anchor: string; element: Element } | "private" | "own" | null {
  for (let element = target; element; element = element.parentElement) {
    if (element.hasAttribute("data-issho-private")) return "private";
    if (element instanceof HTMLInputElement && element.type === "password") return "private";
    if (element.getAttribute("data-issho-cursor") === "own") return "own";
  }
  for (let element = target; element; element = element.parentElement) {
    const anchor = element.getAttribute("data-issho-anchor");
    if (anchor) return { anchor, element };
    if (element.id && element !== document.documentElement && element !== document.body) return { anchor: `#${element.id}`, element };
  }
  return null;
}

/** The element of an anchor on this page, or `null`. */
export function elementOf(anchor: string): Element | null {
  if (anchor === "page") return document.documentElement;
  if (anchor.startsWith("#")) return document.getElementById(anchor.slice(1));
  return document.querySelector(`[data-issho-anchor="${CSS.escape(anchor)}"]`);
}

/** The element of a document's component on this page (the innermost, when they nest). */
function docElement(doc: string): Element | null {
  const all = document.querySelectorAll(`[data-issho-doc="${CSS.escape(doc)}"]`);
  return all.length > 0 ? all[all.length - 1] : null;
}

/** The elements of the page an agent may point at and click: their anchor, label, and whether they take followers along. */
function anchors(): { name: string; label: string; follow?: true }[] {
  const found: { name: string; label: string; follow?: true }[] = [];
  for (const element of document.querySelectorAll<HTMLElement>("[data-issho-anchor]")) {
    if (found.length >= 50 || element.closest("[data-issho-private]")) continue;
    const name = element.dataset.isshoAnchor!;
    const label = (element.getAttribute("aria-label") || element.title || element.textContent || "").replace(/\s+/g, " ").trim().slice(0, 80);
    found.push({ name, label, ...(element.closest("[data-issho-follow]") ? { follow: true as const } : {}) });
  }
  return found;
}

function boxOf(element: Element): Box {
  if (element === document.documentElement) {
    const root = document.documentElement;
    return { left: -window.scrollX, top: -window.scrollY, width: root.scrollWidth, height: root.scrollHeight };
  }
  const rect = element.getBoundingClientRect();
  return { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
}

/** This browser's pointer at a point of the viewport, over an element. */
export function pointerAt(target: Element | null, clientX: number, clientY: number): PagePointer | DocPointer | null {
  // Over a component that says what is under the point: a place of its document.
  const component = target?.closest?.<HTMLElement>("[data-issho-doc]");
  const pointer = component ? (component as Pointed)[POINTER] : undefined;
  if (component && pointer && !target!.closest("[data-issho-private]")) {
    const at = pointer(clientX, clientY);
    if (at !== null && at !== undefined) return { doc: component.dataset.isshoDoc!, at };
  }
  const found = anchorOf(target);
  if (found === "private" || found === "own") return null;
  const element = found?.element ?? document.documentElement;
  return { anchor: found?.anchor ?? "page", ...fractions(boxOf(element), clientX, clientY) };
}

export interface PointerLayerOptions {
  /** Whether this browser shares its pointer (true); it sees the others' either way. */
  share?: boolean;
  /** The room of the page: whom it follows there, and what it says it shows. */
  room?: string;
  /** Says what changed in this browser's state: the room's `aware`. */
  aware: (changes: Record<string, unknown>) => void;
}

/**
 * Draws the others' pointers over the page, into `layer` (a fixed element
 * that covers the viewport and lets clicks through), and shares this
 * browser's. Over a component that says what is under a point of the
 * screen (`point`), a pointer is a place of its document, which each
 * browser draws where that place is on its own screen (`locate`): the
 * pointer goes from component to component as one. It keeps the one this
 * page follows on the screen, clicks the links and buttons they click that
 * take followers along (`data-issho-follow`), and tells the room what this
 * browser shows, so that agents move when someone sees them. Gives a
 * function that stops it; `draw` takes the others.
 */
export function pointerLayer(layer: HTMLElement, options: PointerLayerOptions): { draw: (people: Pointing[]) => void; stop: () => void } {
  const share = options.share ?? true;
  const room = options.room ?? null;
  let people: Pointing[] = [];
  let clicks = 0;
  let last: PagePointer | DocPointer | null = null;
  const seenClicks = new Map<string, number | undefined>();
  const seenMotion = new Map<string, number>();
  const marks = new Map<string, HTMLElement>();
  let frame = 0;
  // An agent's place moves as its document changes under it (text typed
  // before it, a node moved): looked at again while one is drawn there.
  let locating = 0;
  let scrolledTo = "";
  // What the room showed when the page came is not done again: a click an
  // agent made before is not made again for a page that comes after it.
  let primed = false;

  const send = (pointer: PagePointer | DocPointer | null): void => {
    if (!share) return;
    if (pointer === null && last === null) return;
    last = pointer;
    options.aware({ pointer });
  };

  const onMove = (event: PointerEvent): void => {
    if (event.pointerType === "touch") return;
    const pointer = pointerAt(event.target as Element | null, event.clientX, event.clientY);
    send(pointer && last?.click !== undefined ? { ...pointer, click: last.click } : pointer);
  };
  const onDown = (event: PointerEvent): void => {
    const pointer = pointerAt(event.target as Element | null, event.clientX, event.clientY);
    if (pointer) send({ ...pointer, click: ++clicks });
  };
  const onLeave = (): void => send(null);
  const onVisibility = (): void => {
    if (document.visibilityState !== "visible") send(null);
    report();
  };
  const schedule = (): void => {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      render();
    });
  };

  document.addEventListener("pointermove", onMove, { passive: true });
  document.addEventListener("pointerdown", onDown, { passive: true });
  document.documentElement.addEventListener("pointerleave", onLeave);
  window.addEventListener("blur", onLeave);
  document.addEventListener("visibilitychange", onVisibility);
  window.addEventListener("scroll", schedule, { passive: true, capture: true });
  window.addEventListener("resize", schedule);

  // What this browser shows, for the room: the page in the foreground, the
  // documents of the components on the screen (or near it), this person's
  // motion, whom they follow, and the elements of the page an agent may
  // point at. Said when it changes.
  const shown = new Set<string>();
  const seen = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        const doc = (entry.target as HTMLElement).dataset.isshoDoc;
        if (!doc) continue;
        if (entry.isIntersecting) shown.add(doc);
        else shown.delete(doc);
      }
      report();
    },
    { rootMargin: "25%" },
  );
  const watched = new Set<Element>();
  const watch = (): void => {
    for (const element of document.querySelectorAll("[data-issho-doc]")) {
      if (!watched.has(element)) {
        watched.add(element);
        seen.observe(element);
      }
    }
    for (const element of watched) {
      if (!element.isConnected) {
        watched.delete(element);
        seen.unobserve(element);
        const doc = (element as HTMLElement).dataset.isshoDoc;
        if (doc) shown.delete(doc);
      }
    }
    report();
  };
  let watchTimer = 0;
  const changes = new MutationObserver(() => {
    clearTimeout(watchTimer);
    watchTimer = window.setTimeout(watch, 200);
  });
  changes.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["data-issho-doc", "data-issho-anchor"] });
  let reported = "";
  function report(): void {
    if (!room) return;
    const view = {
      page: document.visibilityState === "visible",
      docs: [...shown].sort(),
      motion: motionPreference(),
      follow: following(room),
      anchors: anchors(),
    };
    const signature = JSON.stringify(view);
    if (signature === reported) return;
    reported = signature;
    options.aware({ view });
  }
  const offMotion = onMotion(() => {
    report();
    schedule();
  });
  const onFollowing = (): void => {
    scrolledTo = "";
    report();
    schedule();
  };
  document.addEventListener("issho:following", onFollowing);
  watch();

  function render(): void {
    const viewport = { width: document.documentElement.clientWidth, height: document.documentElement.clientHeight };
    const reduced = motionPreference() === "reduced";
    const followed = room ? following(room) : null;
    const keep = new Set<string>();
    for (const someone of people) {
      const one = onThisPage(someone);
      const spot = spotOf(one, viewport);
      if (!spot) continue;
      keep.add(one.key);
      const known = marks.get(one.key);
      const mark = known ?? createMark(one);
      marks.set(one.key, mark);
      // An agent's new gesture takes the time it said; its other moves (it
      // types, its place follows) are short; with reduced motion, none.
      const gesture = one.motion && seenMotion.get(one.key) !== one.motion.seq ? one.motion : null;
      if (reduced) mark.style.transitionDuration = "0ms";
      else if (gesture) mark.style.transitionDuration = `${gesture.ms}ms`;
      else if (one.kind === "agent") mark.style.transitionDuration = "150ms";
      else mark.style.removeProperty("transition-duration");
      mark.style.setProperty("--issho-color", one.color);
      mark.style.transform = `translate(${Math.round(spot.x)}px, ${Math.round(spot.y)}px)`;
      mark.dataset.edge = spot.edge ?? "";
      mark.dataset.kind = one.kind;
      mark.dataset.gesture = one.motion?.gesture ?? "";
      if (followed === one.key) mark.dataset.followed = "";
      else delete mark.dataset.followed;
      // At a place a component located (an agent's caret, which the component names), the arrow only.
      mark.dataset.at = one.pointer ? "pointer" : atPlace(one) ? "place" : "doc";
      const label = mark.querySelector<HTMLElement>(".issho-pointer-name");
      if (label && label.textContent !== one.name) label.textContent = one.name;
      const button = mark.querySelector<HTMLButtonElement>(".issho-pointer-edge");
      if (button) {
        button.hidden = spot.edge === null;
        button.setAttribute("aria-label", `Go to ${one.name}`);
      }
      // A click rings once, where it is made; a person who comes with one
      // already made does not. An agent's rings when it gets there.
      if (gesture) {
        seenMotion.set(one.key, gesture.seq);
        if (primed && gesture.gesture === "click") window.setTimeout(() => clicked(one, mark), reduced ? 0 : gesture.ms);
      } else {
        const click = one.pointer?.click ?? one.click;
        if (known && click !== undefined && seenClicks.get(one.key) !== click) clicked(one, mark);
        seenClicks.set(one.key, click);
      }
      if (followed === one.key) keepInView(one, spot, viewport);
    }
    // Following someone here: the page has a frame of their colour.
    const frame = followed ? people.find((one) => one.key === followed && keep.has(one.key)) : undefined;
    if (frame) {
      layer.dataset.following = "";
      layer.style.setProperty("--issho-follow-color", frame.color);
    } else {
      delete layer.dataset.following;
    }
    for (const [key, mark] of marks) {
      if (!keep.has(key)) {
        mark.remove();
        marks.delete(key);
      }
    }
    primed = true;
    const located = people.some((one) => !!onThisPage(one).doc);
    if (located && !locating) locating = window.setInterval(schedule, 250);
    if (!located && locating) {
      clearInterval(locating);
      locating = 0;
    }
  }

  // A click of someone: it rings, and when this page follows them, a link
  // or a button that takes followers along is clicked here too, a moment
  // later, so that the ring is seen before the page goes.
  function clicked(one: Pointing, mark: HTMLElement): void {
    ripple(mark);
    if (!room || following(room) !== one.key || !one.pointer) return;
    const element = elementOf(one.pointer.anchor);
    const target = element?.closest<HTMLElement>("[data-issho-follow]");
    if (target) window.setTimeout(() => target.isConnected && target.click(), motionPreference() === "reduced" ? 0 : 150);
  }

  // The one followed stays on the screen: the page scrolls to them when
  // they go where it does not show, once for each place they go.
  function keepInView(one: Pointing, spot: Spot, viewport: { width: number; height: number }): void {
    const where = JSON.stringify(one.pointer ? one.pointer.anchor : [one.doc, one.motion?.seq]);
    if (spot.edge === null) {
      scrolledTo = where;
      return;
    }
    if (scrolledTo === where) return;
    scrolledTo = where;
    const y = spot.edge === "top" || spot.edge === "bottom" ? targetY(one) : null;
    if (y !== null) window.scrollBy({ top: y - viewport.height / 2, behavior: motionPreference() === "reduced" ? "auto" : "smooth" });
  }

  function targetY(one: Pointing): number | null {
    const box = boxFor(one);
    return box ? box.top + box.height / 2 : null;
  }

  function boxFor(one: Pointing): Box | null {
    if (one.pointer) {
      const element = elementOf(one.pointer.anchor);
      if (!element) return null;
      const box = boxOf(element);
      return { left: box.left + one.pointer.x * box.width, top: box.top + one.pointer.y * box.height, width: 0, height: 0 };
    }
    if (one.doc) {
      const element = docElement(one.doc);
      if (!element) return null;
      return (one.at === undefined ? null : (element as Located)[LOCATOR]?.(one.at)) ?? boxOf(element);
    }
    return null;
  }

  function atPlace(one: Pointing): boolean {
    if (!one.doc || one.at === undefined) return false;
    const element = docElement(one.doc);
    return !!element && !!(element as Located)[LOCATOR]?.(one.at);
  }

  // An agent that went to an element of another page (it clicked a link)
  // is drawn where it is in a document here, if it is in one.
  function onThisPage(one: Pointing): Pointing {
    if (!one.pointer || !one.place || elementOf(one.pointer.anchor)) return one;
    return { ...one, pointer: null, doc: one.place.doc, at: one.place.at };
  }

  function spotOf(one: Pointing, viewport: { width: number; height: number }): Spot | null {
    if (one.pointer) {
      const element = elementOf(one.pointer.anchor);
      if (!element || element.closest('[data-issho-cursor="own"]')) return null;
      return place(boxOf(element), one.pointer, viewport);
    }
    if (one.doc) {
      const element = docElement(one.doc);
      if (!element) return null;
      // An agent at work in a component: where its place is (the end of
      // its selection, a node, a cell), else at the component's top end.
      const box = one.at === undefined ? null : (element as Located)[LOCATOR]?.(one.at);
      if (box) return place(box, within(one.at), viewport);
      return place(boxOf(element), { x: 1, y: 0 }, viewport);
    }
    return null;
  }

  function createMark(one: Pointing): HTMLElement {
    const mark = document.createElement("div");
    mark.className = "issho-pointer";
    mark.dataset.key = one.key;
    // The app's own drawing of the pointer, or Issho's arrow and name.
    const own = currentLook().pointer?.(one) ?? null;
    mark.innerHTML = own
      ? '<button type="button" class="issho-pointer-edge" hidden></button>'
      : '<svg class="issho-pointer-arrow" viewBox="0 0 16 16" aria-hidden="true"><path d="M1 1 L1 13 L4.5 9.5 L7 15 L9 14 L6.5 8.5 L11.5 8.5 Z"/></svg>' +
        '<span class="issho-pointer-name"></span>' +
        '<button type="button" class="issho-pointer-edge" hidden></button>';
    if (own) {
      mark.dataset.own = "";
      mark.prepend(own);
    }
    mark.querySelector(".issho-pointer-edge")?.addEventListener("click", () => {
      const found = people.find((person) => person.key === one.key);
      const target = found && onThisPage(found);
      const element = target?.pointer ? elementOf(target.pointer.anchor) : target?.doc ? document.querySelector(`[data-issho-doc="${CSS.escape(target.doc)}"]`) : null;
      element?.scrollIntoView({ block: "center", behavior: "smooth" });
    });
    layer.append(mark);
    return mark;
  }

  function ripple(mark: HTMLElement): void {
    if (motionPreference() === "reduced") return;
    const ring = document.createElement("span");
    ring.className = "issho-pointer-click";
    mark.append(ring);
    ring.addEventListener("animationend", () => ring.remove());
    setTimeout(() => ring.remove(), 1_000);
  }

  return {
    draw(next: Pointing[]): void {
      people = next;
      schedule();
    },
    stop(): void {
      send(null);
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerdown", onDown);
      document.documentElement.removeEventListener("pointerleave", onLeave);
      window.removeEventListener("blur", onLeave);
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("scroll", schedule, { capture: true });
      window.removeEventListener("resize", schedule);
      if (frame) cancelAnimationFrame(frame);
      if (locating) clearInterval(locating);
      clearTimeout(watchTimer);
      seen.disconnect();
      changes.disconnect();
      offMotion();
      document.removeEventListener("issho:following", onFollowing);
      for (const mark of marks.values()) mark.remove();
      marks.clear();
    },
  };
}
