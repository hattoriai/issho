// The people of a room, drawn: an avatar for each person or agent, in
// their colour, the agents marked with whom they act for, the viewers as
// viewers, and what each says they are doing (their awareness "status").
// The same markup as Issho.Components.people/1 renders on the server, so
// one theme (issho.css, issho-sumi.css) styles both.

import type { Peer } from "./awareness";
import { follow, following } from "./follow";
import type { Person } from "./presence";
import { currentLook } from "./theme";

export interface PeopleOptions {
  /** How many avatars before "+N" (8). */
  max?: number;
  /** The list's accessible name ("People here"). */
  label?: string;
  /** The room the list is of: a click on someone follows them there. Without it, no one is followed. */
  room?: string;
}

/** The view of the people the list draws: a person and what they are doing. */
export interface Someone {
  person: Person;
  status: string | null;
  you: boolean;
}

/** The people of the room as the list shows them: this actor first, then in the order they came. */
export function someone(everyone: Person[], peers: Peer[], self: string): Someone[] {
  const statuses = new Map<string, string>();
  for (const peer of peers) {
    const status = (peer.state as { status?: unknown }).status;
    if (typeof status === "string" && status !== "") statuses.set(peer.key, status);
  }
  return everyone
    .map((person) => ({ person, status: statuses.get(person.key) ?? null, you: person.key === self }))
    .sort((a, b) => Number(b.you) - Number(a.you));
}

/** Draws the people into an element, replacing what it held. */
export function drawPeople(element: HTMLElement, people: Someone[], options: PeopleOptions = {}): void {
  const max = options.max ?? 8;
  const list = document.createElement("ul");
  list.className = "issho-people";
  list.setAttribute("aria-label", options.label ?? "People here");

  const room = options.room;
  for (const one of people.slice(0, max)) list.append(item(one, room));

  if (people.length > max) {
    const more = document.createElement("li");
    more.className = "issho-person issho-person-more";
    more.textContent = `+${people.length - max}`;
    more.title = people.slice(max).map((one) => describe(one)).join("\n");
    list.append(more);
  }

  // Whom this tab follows, with a way to stop.
  const followed = room ? people.find((one) => one.person.key === following(room) && !one.you) : undefined;
  if (followed) {
    const line = document.createElement("p");
    line.className = "issho-following";
    line.dataset.isshoFollowControl = "";
    line.setAttribute("role", "status");
    line.style.setProperty("--issho-color", followed.person.color ?? `var(--issho-person-${followed.person.palette})`);
    const text = document.createElement("span");
    text.textContent = `Following ${followed.person.name ?? followed.person.key}`;
    const stop = document.createElement("button");
    stop.type = "button";
    stop.className = "issho-following-stop";
    stop.textContent = "Stop";
    stop.addEventListener("click", () => follow(room!, null));
    line.append(text, stop);
    element.replaceChildren(list, line);
  } else {
    element.replaceChildren(list);
  }
}

function item({ person, status, you }: Someone, room?: string): HTMLLIElement {
  const li = document.createElement("li");
  li.className = "issho-person";
  li.dataset.kind = person.kind;
  li.dataset.key = person.key;
  if (person.can === "read") li.dataset.viewing = "";
  if (you) li.dataset.you = "";
  li.style.setProperty("--issho-color", person.color ?? `var(--issho-person-${person.palette})`);
  li.title = describe({ person, status, you });

  // Someone else: a button that follows them, or stops.
  let into: HTMLElement = li;
  if (room && !you) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "issho-person-follow";
    button.dataset.isshoFollowControl = "";
    const followed = following(room) === person.key;
    if (followed) li.dataset.followed = "";
    button.setAttribute("aria-pressed", String(followed));
    button.addEventListener("click", () => follow(room, following(room) === person.key ? null : person.key));
    li.append(button);
    into = button;
  }

  // The app's own drawing of the person, or Issho's avatar.
  const own = currentLook().person?.({ person, status, you }) ?? null;
  if (own) {
    if (own instanceof Element) own.setAttribute("aria-hidden", "true");
    into.append(own);
  } else {
    const avatar = document.createElement("span");
    avatar.className = "issho-avatar";
    avatar.setAttribute("aria-hidden", "true");
    if (person.avatar) {
      const image = document.createElement("img");
      image.src = person.avatar;
      image.alt = "";
      avatar.append(image);
    } else avatar.textContent = initials(person.name ?? person.key);
    into.append(avatar);
  }

  if ((person.kind === "agent" || person.kind === "service") && !own) {
    const badge = document.createElement("span");
    badge.className = "issho-badge";
    badge.setAttribute("aria-hidden", "true");
    badge.textContent = person.kind === "agent" ? "AI" : "App";
    into.append(badge);
  }

  // What a screen reader reads, and what the theme may show beside the avatar.
  const label = document.createElement("span");
  label.className = "issho-person-label";
  label.textContent = describe({ person, status, you });
  into.append(label);

  if (status) {
    const doing = document.createElement("span");
    doing.className = "issho-status";
    doing.setAttribute("aria-hidden", "true");
    doing.textContent = status;
    into.append(doing);
  }
  return li;
}

/** One line about someone: "Claude Code, an agent for Ada: Renaming". */
export function describe({ person, status, you }: Someone): string {
  let text = person.name ?? person.key;
  if (you) text += " (you)";
  if (person.kind === "agent") text += person.on_behalf_of ? `, an agent for ${person.on_behalf_of.name ?? person.on_behalf_of.key}` : ", an agent";
  if (person.kind === "service") text += ", the app";
  if (person.kind === "guest") text += ", a visitor";
  if (person.can === "read") text += ", viewing";
  if (status) text += `: ${status}`;
  return text;
}

function initials(name: string): string {
  const words = name.replace(/^[a-z]+:/i, "").split(/[\s._-]+/).filter(Boolean);
  const letters = words.length > 1 ? words[0][0] + words[words.length - 1][0] : (words[0] ?? "?").slice(0, 2);
  return letters.toUpperCase();
}
