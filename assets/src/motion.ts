// How much this person wants to see others move: "full" (pointers glide,
// carets travel, selections sweep) or "reduced" (they are there at once).
// It is the app's to say, from its own settings: `setMotion("reduced")`, or
// `data-issho-motion="reduced"` on the page's root element; else the
// browser's "reduce motion" setting says it. Issho tells the room, so that
// agents do not wait to be seen moving by someone who does not want it.
//
// A component reads it without importing Issho: the root element's
// `data-issho-motion` (`reduced` or `full`), else the media query, and the
// `issho:motion` event on `document` when it changes.

export type Motion = "full" | "reduced";

/** This person's motion: the app's word for it, else the browser's setting. */
export function motion(): Motion {
  if (typeof document === "undefined") return "full";
  const said = document.documentElement.dataset.isshoMotion;
  if (said === "full" || said === "reduced") return said;
  return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches ? "reduced" : "full";
}

/** Says how much this person wants to see others move (`null`: as the browser says). */
export function setMotion(value: Motion | null): void {
  const root = document.documentElement;
  if (value) root.dataset.isshoMotion = value;
  else delete root.dataset.isshoMotion;
  document.dispatchEvent(new CustomEvent("issho:motion", { detail: { motion: motion() } }));
}

/** Calls `listener` when this person's motion changes. Gives a function that stops it. */
export function onMotion(listener: (value: Motion) => void): () => void {
  const handler = (): void => listener(motion());
  document.addEventListener("issho:motion", handler);
  const media = typeof matchMedia === "function" ? matchMedia("(prefers-reduced-motion: reduce)") : null;
  media?.addEventListener?.("change", handler);
  return () => {
    document.removeEventListener("issho:motion", handler);
    media?.removeEventListener?.("change", handler);
  };
}
