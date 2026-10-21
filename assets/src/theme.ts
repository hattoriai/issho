// How Issho's pieces of a page look, beyond the theme's custom properties:
// an app draws a person of the list, or a pointer, with its own markup.
//
//     import { configure } from "issho"
//
//     configure({
//       person: ({ person }) => myAvatar(person.name, person.avatar),
//       pointer: ({ name, color }) => myCursor(name, color),
//     })
//
// A function gives an element, or null for Issho's own. Issho keeps what
// the element sits in: its place, its colour (`--issho-color`), its data
// attributes and what a screen reader hears.

import type { Someone } from "./people";
import type { Pointing } from "./pointers";

export interface Look {
  /** A person of the list: what shows in their item, in place of the avatar. */
  person?: (someone: Someone) => Node | null;
  /** A pointer over the page: what shows at the point, in place of the arrow and the name. */
  pointer?: (pointing: Pointing) => Node | null;
}

let look: Look = {};

/** Sets how Issho's pieces of a page look; each call merges into the last. */
export function configure(changes: Look): void {
  look = { ...look, ...changes };
}

/** How the app said Issho's pieces look. */
export function currentLook(): Look {
  return look;
}
