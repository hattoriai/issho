// Issho's LiveView hooks, for the LiveSocket's hooks:
//
//     import { Hooks as IsshoHooks } from "issho"
//     new LiveSocket("/live", Socket, { hooks: { ...IsshoHooks, ...yours } })
//
// IsshoPeople draws the people of the room of its grant
// (Issho.Components.people/1), live; IsshoPointers the pointers of the
// room's people over the page (Issho.Components.pointers/1).

import { requestGrant, type Grant, type LiveHook } from "./grant";
import { joinRoom, releaseRoom } from "./page";
import { follow, following, onFollow, stopOnOwnWay } from "./follow";
import { motion, onMotion, setMotion } from "./motion";
import { drawPeople, someone } from "./people";
import { commentMarkers, type Marked } from "./comments";
import { atWork, drawAgents } from "./agents";
import { gestureTracker, pointerLayer, pointing, type Gestures } from "./pointers";

interface Hook extends LiveHook {
  el: HTMLElement;
}

interface PeopleHook extends Hook {
  stop?: () => void;
  room?: string;
}

const IsshoPeople = {
  mounted(this: PeopleHook): void {
    const grant = JSON.parse(this.el.dataset.grant ?? "{}") as Grant;
    const max = Number(this.el.dataset.max ?? 8);
    const label = this.el.dataset.label;
    this.room = grant.room;
    void joinRoom(grant.room, {
      token: grant.token,
      self: grant.self,
      socket: grant.socket,
      maxChannels: grant.max_channels,
      renew: async () => (await requestGrant(this, grant.room)).token,
    }).then(
      (room) => {
        const followable = this.el.dataset.follow !== "false";
        const draw = (): void =>
          drawPeople(this.el, someone(room.presence.everyone, room.awareness.peers, grant.self), { max, label, room: followable ? grant.room : undefined });
        const offPresence = room.presence.on(draw);
        const offAwareness = room.awareness.on(draw);
        const offFollow = onFollow(grant.room, draw);
        // Someone followed who left the room is followed no more.
        const offLeft = room.presence.on(() => {
          const key = following(grant.room);
          if (key && !room.presence.everyone.some((person) => person.key === key)) follow(grant.room, null);
        });
        this.stop = () => {
          offPresence();
          offAwareness();
          offFollow();
          offLeft();
        };
        draw();
      },
      () => {
        this.el.dataset.state = "unavailable";
      },
    );
  },

  destroyed(this: PeopleHook): void {
    this.stop?.();
    if (this.room) void releaseRoom(this.room);
  },
};

const IsshoPointers = {
  mounted(this: PeopleHook): void {
    const grant = JSON.parse(this.el.dataset.grant ?? "{}") as Grant;
    this.room = grant.room;
    // The person's motion, as the app said it from its settings.
    const said = this.el.dataset.motion;
    if (said === "full" || said === "reduced") setMotion(said);
    void joinRoom(grant.room, {
      token: grant.token,
      self: grant.self,
      socket: grant.socket,
      maxChannels: grant.max_channels,
      renew: async () => (await requestGrant(this, grant.room)).token,
    }).then(
      (room) => {
        const layer = pointerLayer(this.el, {
          share: this.el.dataset.share !== "false",
          room: grant.room,
          aware: (changes) => room.aware(changes as Parameters<typeof room.aware>[0]),
        });
        // An agent at work for this person is followed when it starts to
        // move (`follow-agents="on_behalf"`), unless they stopped following
        // it on this page.
        const followAgents = this.el.dataset.followAgents === "on_behalf";
        const declined = new Set<string>();
        const followMine = (gestures: Gestures): void => {
          if (!followAgents) return;
          for (const peer of room.awareness.peers) {
            if (!gestures.fresh.has(peer.session)) continue;
            const agent = room.presence.everyone.find((person) => person.key === peer.key);
            if (agent?.kind !== "agent" || agent.on_behalf_of?.key !== grant.self) continue;
            if (!following(grant.room) && !declined.has(agent.key)) follow(grant.room, agent.key);
          }
        };
        let followed = following(grant.room);
        const offFollowing = onFollow(grant.room, (key) => {
          if (followed && key === null && room.presence.everyone.some((person) => person.key === followed)) declined.add(followed);
          followed = key;
          frame();
        });
        // The one followed goes to another page (an agent's `navigate`):
        // this page goes there too. A gesture seen when the page came is
        // where they already were; only a path of this app is followed.
        const goAlong = (gestures: Gestures): void => {
          const key = following(grant.room);
          for (const peer of room.awareness.peers) {
            if (!gestures.fresh.has(peer.session) || peer.key !== key) continue;
            const gesture = (peer.state as { motion?: { gesture?: unknown; to?: { path?: unknown } } }).motion;
            if (gesture?.gesture !== "navigate") continue;
            const path = gesture.to?.path;
            if (typeof path !== "string" || !path.startsWith("/") || path.startsWith("//")) continue;
            if (path === location.pathname + location.search) continue;
            const js = (this as unknown as { js?: () => { navigate: (href: string) => void } }).js;
            if (js) js.call(this).navigate(path);
            else location.assign(path);
          }
        };
        // Following someone of the room: the page has a frame of their
        // colour, whether their pointer is on it or not.
        const frame = (): void => {
          const key = following(grant.room);
          const person = key ? room.presence.everyone.find((one) => one.key === key) : undefined;
          if (person) {
            this.el.dataset.following = "";
            this.el.style.setProperty("--issho-follow-color", person.color ?? `var(--issho-person-${person.palette})`);
          } else {
            delete this.el.dataset.following;
          }
        };
        // Each gesture of the agents is new once, for all of the above.
        const track = gestureTracker();
        const draw = (): void => {
          const gestures = track(room.awareness.peers, (session) => room.awareness.wasThere(session));
          followMine(gestures);
          goAlong(gestures);
          frame();
          layer.draw(pointing(room.awareness.peers, room.presence.everyone, grant.self, gestures));
        };
        const offPresence = room.presence.on(draw);
        const offAwareness = room.awareness.on(draw);
        // On an Issho page, going one's own way on it ends following.
        const offOwnWay = stopOnOwnWay(grant.room);
        this.stop = () => {
          offPresence();
          offAwareness();
          offOwnWay();
          offFollowing();
          layer.stop();
        };
        draw();
      },
      () => {
        this.el.dataset.state = "unavailable";
      },
    );
  },

  destroyed(this: PeopleHook): void {
    this.stop?.();
    if (this.room) void releaseRoom(this.room);
  },
};

interface MotionHook extends Hook {
  stop?: () => void;
}

// A switch for how much this person wants to see others move.
const IsshoMotion = {
  mounted(this: MotionHook): void {
    const show = (): void => this.el.setAttribute("aria-pressed", String(motion() === "full"));
    const toggle = (): void => {
      const next = motion() === "full" ? "reduced" : "full";
      setMotion(next);
      const event = this.el.dataset.event;
      if (event) this.pushEvent(event, { motion: next }, () => {});
    };
    this.el.addEventListener("click", toggle);
    const off = onMotion(show);
    show();
    this.stop = () => {
      this.el.removeEventListener("click", toggle);
      off();
    };
  },

  destroyed(this: MotionHook): void {
    this.stop?.();
  },
};

interface CommentsHook extends Hook {
  markers?: ReturnType<typeof commentMarkers>;
  focused?: string | null;
  handleEvent(event: string, callback: (payload: never) => void): void;
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void;
}

// The threads of comments of a room (Issho.Components.comments/1): a mark
// at each thread's place on the page, the times in the person's own
// words, the page scrolled to a thread's place, and the thread chosen in
// the panel.
const IsshoComments = {
  mounted(this: CommentsHook): void {
    if (this.el.dataset.marks !== "false")
      this.markers = commentMarkers({ open: (thread) => this.pushEventTo(this.el, "focus", { thread }) });
    this.handleEvent("issho:comments:show", ({ doc }: { doc: string }) => {
      const element = document.querySelector(`[data-issho-doc="${CSS.escape(doc)}"]`);
      const smooth = !window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
      element?.scrollIntoView({ block: "center", behavior: smooth ? "smooth" : "auto" });
    });
    IsshoComments.updated.call(this);
  },

  updated(this: CommentsHook): void {
    const threads = JSON.parse(this.el.dataset.threads ?? "[]") as Marked[];
    const focused = this.el.dataset.focused || null;
    this.markers?.draw(threads, focused);
    localTimes(this.el);
    if (focused && focused !== this.focused) {
      this.el.querySelector(`[data-thread="${CSS.escape(focused)}"]`)?.scrollIntoView({ block: "nearest" });
    }
    this.focused = focused;
  },

  destroyed(this: CommentsHook): void {
    this.markers?.stop();
  },
};

// The times of a page, as the server writes them (UTC), in the person's
// own locale and time zone.
function localTimes(root: HTMLElement): void {
  const format = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
  for (const time of root.querySelectorAll<HTMLTimeElement>("time[datetime]")) {
    const date = new Date(time.dateTime);
    if (!Number.isNaN(date.getTime())) time.textContent = format.format(date);
  }
}

// The agents at work in the room of its grant (Issho.Components.agents/1):
// each one's task and steps, live, and Pause, Resume and Stop.
const IsshoAgents = {
  mounted(this: PeopleHook): void {
    const grant = JSON.parse(this.el.dataset.grant ?? "{}") as Grant;
    this.room = grant.room;
    void joinRoom(grant.room, {
      token: grant.token,
      self: grant.self,
      socket: grant.socket,
      maxChannels: grant.max_channels,
      renew: async () => (await requestGrant(this, grant.room)).token,
    }).then(
      (room) => {
        const options = {
          anyone: this.el.dataset.anyone === "true",
          label: this.el.dataset.label,
          interrupt: (agent: string, action: "pause" | "resume" | "stop") => {
            room.interrupt(agent, action).catch(() => {
              this.el.dataset.refused = action;
            });
          },
        };
        const draw = (): void => drawAgents(this.el, atWork(room.awareness.peers, room.presence.everyone, grant.self), options);
        const offPresence = room.presence.on(draw);
        const offAwareness = room.awareness.on(draw);
        this.stop = () => {
          offPresence();
          offAwareness();
        };
        draw();
      },
      () => {
        this.el.dataset.state = "unavailable";
      },
    );
  },

  destroyed(this: PeopleHook): void {
    this.stop?.();
    if (this.room) void releaseRoom(this.room);
  },
};

export const Hooks = { IsshoPeople, IsshoPointers, IsshoMotion, IsshoComments, IsshoAgents };
