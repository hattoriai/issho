// The icons the browser's half draws: Lucide icons (https://lucide.dev,
// ISC licence), strokes of currentColor, as Issho.Icons draws them on the
// server.

const shapes = {
  pause: '<rect x="14" y="4" width="4" height="16" rx="1"/><rect x="6" y="4" width="4" height="16" rx="1"/>',
  play: '<polygon points="6 3 20 12 6 21 6 3"/>',
  square: '<rect width="14" height="14" x="5" y="5" rx="2"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  circle: '<circle cx="12" cy="12" r="9"/>',
  minus: '<path d="M5 12h14"/>',
  "chevron-down": '<path d="m6 9 6 6 6-6"/>',
} as const;

export type IconName = keyof typeof shapes;

/** An icon, hidden from screen readers (its button says what it does). */
export function icon(name: IconName, className = "issho-icon"): SVGSVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", className);
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "2");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("focusable", "false");
  svg.innerHTML = shapes[name];
  return svg;
}
