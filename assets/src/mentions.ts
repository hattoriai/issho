// The @ of a comment: typing it opens a list of the people of the room and
// the app's `mentionable`, filtered as one types, as Kotoba's mentions
// menu is. Picking one writes "@Name " in the text and keeps their key, so
// the comment mentions who was picked, not whoever has that name.

/** Someone a comment may mention, as Issho.Components.comments/1 lists them. */
export interface Candidate {
  key: string;
  name: string;
  kind?: string;
  color?: string | null;
  palette?: number;
  /** Whether they are in the room now. */
  here?: boolean;
}

/** The @ being typed before the caret, and what follows it: `null` when there is none. */
export function mentionQuery(text: string, caret: number): { start: number; query: string } | null {
  const before = text.slice(0, caret);
  const at = before.lastIndexOf("@");
  if (at < 0) return null;
  // An @ at the start, or after a space or a line: not in an address.
  if (at > 0 && !/\s/.test(before[at - 1])) return null;
  const query = before.slice(at + 1);
  // A name has spaces, but not two together, nor a line, nor much length.
  if (query.length > 40 || /\n|\s\s/.test(query)) return null;
  return { start: at, query };
}

const fold = (text: string): string => text.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();

/**
 * The candidates for a query: those whose name, or one of its words,
 * begins with it, ignoring case and accents; those in the room first,
 * then by name. At most `max`.
 */
export function matchCandidates(candidates: Candidate[], query: string, max = 8): Candidate[] {
  const wanted = fold(query.trim());
  return candidates
    .filter((one) => {
      if (wanted === "") return true;
      const name = fold(one.name);
      return name.startsWith(wanted) || name.split(/\s+/).some((word) => word.startsWith(wanted));
    })
    .sort((a, b) => Number(!!b.here) - Number(!!a.here) || a.name.localeCompare(b.name))
    .slice(0, max);
}

/** Whether a query is a whole name and the space after it: a mention written, not one being typed. */
export function finished(query: string, candidates: Candidate[]): boolean {
  if (!/\s$/.test(query)) return false;
  const name = fold(query.trim());
  return candidates.some((one) => fold(one.name) === name);
}

/** The text with the @ query replaced by the name, and where the caret goes. */
export function insertMention(text: string, start: number, caret: number, name: string): { text: string; caret: number } {
  const inserted = `@${name} `;
  return { text: text.slice(0, start) + inserted + text.slice(caret), caret: start + inserted.length };
}

let lists = 0;

/**
 * The picker of a text area: a list under it while an @ is typed, with the
 * keyboard of a list box (the arrows, Enter or Tab to pick, Escape). Each
 * pick's key is added to `keys`, the form's field of the mentions picked.
 * Gives a function that takes it away.
 */
export function mentionPicker(textarea: HTMLTextAreaElement, keys: HTMLInputElement, candidates: () => Candidate[]): () => void {
  const list = document.createElement("ul");
  list.className = "issho-mention-list";
  list.id = `issho-mentions-${++lists}`;
  list.setAttribute("role", "listbox");
  list.setAttribute("aria-label", "People to mention");
  list.hidden = true;
  document.body.appendChild(list);
  textarea.setAttribute("aria-autocomplete", "list");
  textarea.setAttribute("aria-controls", list.id);

  let shown: Candidate[] = [];
  let active = 0;
  let query: { start: number; query: string } | null = null;

  const close = (): void => {
    list.hidden = true;
    shown = [];
    query = null;
    textarea.removeAttribute("aria-activedescendant");
    textarea.setAttribute("aria-expanded", "false");
  };

  const draw = (): void => {
    list.replaceChildren(
      ...shown.map((one, index) => {
        const item = document.createElement("li");
        item.id = `${list.id}-${index}`;
        item.className = "issho-mention-option";
        item.setAttribute("role", "option");
        item.setAttribute("aria-selected", String(index === active));
        item.dataset.kind = one.kind ?? "human";
        item.style.setProperty("--issho-color", one.color ?? `var(--issho-person-${one.palette ?? 1})`);
        const avatar = document.createElement("span");
        avatar.className = "issho-mention-avatar";
        avatar.setAttribute("aria-hidden", "true");
        avatar.textContent = one.name.slice(0, 1).toUpperCase();
        const name = document.createElement("span");
        name.className = "issho-mention-name";
        name.textContent = one.name;
        item.append(avatar, name);
        if (one.kind === "agent") {
          const badge = document.createElement("span");
          badge.className = "issho-mention-badge";
          badge.textContent = "Agent";
          item.append(badge);
        }
        // A press, not a click: the text area keeps the focus.
        item.addEventListener("mousedown", (event) => {
          event.preventDefault();
          pick(index);
        });
        return item;
      }),
    );
    const box = textarea.getBoundingClientRect();
    list.style.left = `${Math.round(box.left)}px`;
    list.style.top = `${Math.round(box.bottom + 4)}px`;
    list.style.minWidth = `${Math.round(Math.min(box.width, 280))}px`;
    list.hidden = false;
    textarea.setAttribute("aria-expanded", "true");
    textarea.setAttribute("aria-activedescendant", `${list.id}-${active}`);
  };

  const update = (): void => {
    query = mentionQuery(textarea.value, textarea.selectionStart ?? textarea.value.length);
    shown = query && !finished(query.query, candidates()) ? matchCandidates(candidates(), query.query) : [];
    if (shown.length === 0) return close();
    active = Math.min(active, shown.length - 1);
    draw();
  };

  const pick = (index: number): void => {
    const one = shown[index];
    if (!one || !query) return;
    const next = insertMention(textarea.value, query.start, textarea.selectionStart ?? textarea.value.length, one.name);
    textarea.value = next.text;
    textarea.setSelectionRange(next.caret, next.caret);
    const picked = new Set(keys.value.split(",").filter(Boolean));
    picked.add(one.key);
    keys.value = [...picked].join(",");
    close();
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  };

  const onKey = (event: KeyboardEvent): void => {
    if (list.hidden) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      active = (active + (event.key === "ArrowDown" ? 1 : shown.length - 1)) % shown.length;
      draw();
    } else if (event.key === "Enter" || event.key === "Tab") {
      event.preventDefault();
      pick(active);
    } else if (event.key === "Escape") {
      event.preventDefault();
      close();
    }
  };

  const onInput = (): void => {
    active = 0;
    update();
  };

  textarea.addEventListener("keydown", onKey);
  textarea.addEventListener("input", onInput);
  textarea.addEventListener("click", update);
  textarea.addEventListener("blur", close);
  return () => {
    textarea.removeEventListener("keydown", onKey);
    textarea.removeEventListener("input", onInput);
    textarea.removeEventListener("click", update);
    textarea.removeEventListener("blur", close);
    list.remove();
  };
}
