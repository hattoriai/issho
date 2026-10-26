// Who is in a room, from Phoenix.Presence's state and diffs: one person per
// actor key, however many tabs they have open.

export interface Person {
  key: string;
  name: string | null;
  avatar: string | null;
  color: string | null;
  /** The theme's palette index (1 to 8) for a person with no colour. */
  palette: number;
  kind: "human" | "agent" | "service" | "guest";
  on_behalf_of: Person | null;
  joined_at: number;
  /** "write" when any of the person's tabs may write; "read" for someone only viewing. */
  can: "read" | "write";
}

type Meta = Omit<Person, "on_behalf_of"> & { on_behalf_of: Person | null; phx_ref?: string };
type PresenceState = Record<string, { metas: Meta[] }>;
type PresenceDiff = { joins: PresenceState; leaves: PresenceState };

export type PresenceEvent = { type: "join" | "leave"; person: Person } | { type: "change"; people: Person[] };

export class Presence {
  private state: PresenceState = {};
  private listeners = new Set<(event: PresenceEvent) => void>();

  constructor(private readonly self: string) {}

  on(listener: (event: PresenceEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** Everyone in the room but this actor, in the order they joined. */
  get others(): Person[] {
    return this.everyone.filter((person) => person.key !== this.self);
  }

  /** Everyone in the room, this actor included. */
  get everyone(): Person[] {
    return Object.entries(this.state)
      .map(([key, { metas }]) => person(key, metas))
      .sort((a, b) => a.joined_at - b.joined_at || a.key.localeCompare(b.key));
  }

  /** The whole state, as the channel pushes it after a join (or a rejoin). */
  syncState(next: PresenceState): void {
    const before = new Set(Object.keys(this.state));
    this.state = clone(next);
    const after = new Set(Object.keys(this.state));
    for (const key of after) if (!before.has(key)) this.announce("join", key);
    this.emitChange();
  }

  /** A diff: metas of tabs that joined and left. */
  syncDiff({ joins, leaves }: PresenceDiff): void {
    const joined: string[] = [];
    const left: Person[] = [];

    for (const [key, { metas }] of Object.entries(joins)) {
      if (!this.state[key]) {
        this.state[key] = { metas: [] };
        joined.push(key);
      }
      const refs = new Set(this.state[key].metas.map((meta) => meta.phx_ref));
      this.state[key].metas.push(...metas.filter((meta) => !refs.has(meta.phx_ref)));
    }

    for (const [key, { metas }] of Object.entries(leaves)) {
      const current = this.state[key];
      if (!current) continue;
      const refs = new Set(metas.map((meta) => meta.phx_ref));
      current.metas = current.metas.filter((meta) => !refs.has(meta.phx_ref));
      if (current.metas.length === 0) {
        left.push(person(key, metas));
        delete this.state[key];
      }
    }

    for (const key of joined) this.announce("join", key);
    for (const gone of left) if (gone.key !== this.self) this.emit({ type: "leave", person: gone });
    if (joined.length > 0 || left.length > 0 || Object.keys(joins).length > 0) this.emitChange();
  }

  private announce(type: "join", key: string): void {
    if (key === this.self) return;
    this.emit({ type, person: person(key, this.state[key].metas) });
  }

  private emitChange(): void {
    this.emit({ type: "change", people: this.others });
  }

  private emit(event: PresenceEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}

// A person from their tabs' metas: the first tab to join, writing if any tab may.
function person(key: string, metas: Meta[]): Person {
  const first = [...metas].sort((a, b) => a.joined_at - b.joined_at)[0];
  const { phx_ref: _ref, ...rest } = first;
  const can = metas.some((meta) => meta.can === "write") ? "write" : "read";
  return { ...rest, key, can };
}

function clone(state: PresenceState): PresenceState {
  return Object.fromEntries(Object.entries(state).map(([key, { metas }]) => [key, { metas: [...metas] }]));
}
