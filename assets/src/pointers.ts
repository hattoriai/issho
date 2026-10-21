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
import type { Person } from "./presence";
import { currentLook } from "./theme";

export type PagePointer = {
  anchor: string;
  x: number;
  y: number;
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
}

/** Where a place of a document is in the viewport (its `at`), or `null`. */
export type Locator = (at: unknown) => Box | null;

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
    const pointer = asPointer(peer.state.pointer);
    const doc = docOf(peer.state.place);
    if (!pointer && !doc) continue;
    const person = people.get(peer.key);
    const one: Pointing = {
      key: peer.key,
      name: person?.name ?? peer.key,
      color: person?.color ?? `var(--issho-person-${person?.palette ?? 1})`,
      kind: person?.kind ?? "human",
      pointer,
      doc: pointer ? null : doc,
      ...(pointer ? {} : { at: atOf(peer.state.place) }),
    };
    const before = chosen.get(peer.key);
    // A pointer wins over a place: the session that moved is the one with a pointer.
    if (!before || (!before.pointer && pointer)) chosen.set(peer.key, one);
  }
  return [...chosen.values()].sort((a, b) => a.name.localeCompare(b.name));
}

function asPointer(value: unknown): PagePointer | null {
  if (typeof value !== "object" || value === null) return null;
  const { anchor, x, y, click } = value as Record<string, unknown>;
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

function boxOf(element: Element): Box {
  if (element === document.documentElement) {
    const root = document.documentElement;
    return { left: -window.scrollX, top: -window.scrollY, width: root.scrollWidth, height: root.scrollHeight };
  }
  const rect = element.getBoundingClientRect();
  return { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
}

/** This browser's pointer at a point of the viewport, over an element. */
export function pointerAt(target: Element | null, clientX: number, clientY: number): PagePointer | null {
  const found = anchorOf(target);
  if (found === "private" || found === "own") return null;
  const element = found?.element ?? document.documentElement;
  return { anchor: found?.anchor ?? "page", ...fractions(boxOf(element), clientX, clientY) };
}

export interface PointerLayerOptions {
  /** Whether this browser shares its pointer (true); it sees the others' either way. */
  share?: boolean;
  /** Says what changed in this browser's pointer: the room's `aware`. */
  aware: (changes: { pointer: PagePointer | null }) => void;
}

/**
 * Draws the others' pointers over the page, into `layer` (a fixed element
 * that covers the viewport and lets clicks through), and shares this
 * browser's. Gives a function that stops it; `draw` takes the others.
 */
export function pointerLayer(layer: HTMLElement, options: PointerLayerOptions): { draw: (people: Pointing[]) => void; stop: () => void } {
  const share = options.share ?? true;
  let people: Pointing[] = [];
  let clicks = 0;
  let last: PagePointer | null = null;
  const seenClicks = new Map<string, number | undefined>();
  const marks = new Map<string, HTMLElement>();
  let frame = 0;
  // An agent's place moves as its document changes under it (text typed
  // before it, a node moved): looked at again while one is drawn there.
  let follow = 0;

  const send = (pointer: PagePointer | null): void => {
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

  function render(): void {
    const viewport = { width: document.documentElement.clientWidth, height: document.documentElement.clientHeight };
    const keep = new Set<string>();
    for (const one of people) {
      const spot = spotOf(one, viewport);
      if (!spot) continue;
      keep.add(one.key);
      const known = marks.get(one.key);
      const mark = known ?? createMark(one);
      marks.set(one.key, mark);
      mark.style.setProperty("--issho-color", one.color);
      mark.style.transform = `translate(${Math.round(spot.x)}px, ${Math.round(spot.y)}px)`;
      mark.dataset.edge = spot.edge ?? "";
      mark.dataset.kind = one.kind;
      mark.dataset.at = one.pointer ? "pointer" : "doc";
      const label = mark.querySelector<HTMLElement>(".issho-pointer-name");
      if (label && label.textContent !== one.name) label.textContent = one.name;
      const button = mark.querySelector<HTMLButtonElement>(".issho-pointer-edge");
      if (button) {
        button.hidden = spot.edge === null;
        button.setAttribute("aria-label", `Go to ${one.name}`);
      }
      // A click rings once; a person who comes with one already made does not.
      const click = one.pointer?.click;
      if (known && click !== undefined && seenClicks.get(one.key) !== click) ripple(mark);
      seenClicks.set(one.key, click);
    }
    for (const [key, mark] of marks) {
      if (!keep.has(key)) {
        mark.remove();
        marks.delete(key);
      }
    }
    const located = people.some((one) => !one.pointer && one.doc);
    if (located && !follow) follow = window.setInterval(schedule, 250);
    if (!located && follow) {
      clearInterval(follow);
      follow = 0;
    }
  }

  function spotOf(one: Pointing, viewport: { width: number; height: number }): Spot | null {
    if (one.pointer) {
      const element = elementOf(one.pointer.anchor);
      if (!element || element.closest('[data-issho-cursor="own"]')) return null;
      return place(boxOf(element), one.pointer, viewport);
    }
    if (one.doc) {
      const element = document.querySelector(`[data-issho-doc="${CSS.escape(one.doc)}"]`);
      if (!element) return null;
      // An agent at work in a component: where its place is (the end of
      // its selection, a node, a cell), else at the component's top end.
      const box = one.at === undefined ? null : (element as Located)[LOCATOR]?.(one.at);
      if (box) return place(box, { x: 1, y: 1 }, viewport);
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
      const target = people.find((person) => person.key === one.key);
      const element = target?.pointer ? elementOf(target.pointer.anchor) : target?.doc ? document.querySelector(`[data-issho-doc="${CSS.escape(target.doc)}"]`) : null;
      element?.scrollIntoView({ block: "center", behavior: "smooth" });
    });
    layer.append(mark);
    return mark;
  }

  function ripple(mark: HTMLElement): void {
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
      if (follow) clearInterval(follow);
      for (const mark of marks.values()) mark.remove();
      marks.clear();
    },
  };
}
