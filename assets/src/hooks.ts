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
import { pointerLayer, pointing } from "./pointers";

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
        const moved = new Map<string, number>();
        const followMine = (): void => {
          if (!followAgents) return;
          for (const peer of room.awareness.peers) {
            const seq = (peer.state as { motion?: { seq?: number } }).motion?.seq;
            if (typeof seq !== "number" || moved.get(peer.key) === seq) continue;
            moved.set(peer.key, seq);
            const agent = room.presence.everyone.find((person) => person.key === peer.key);
            if (agent?.kind !== "agent" || agent.on_behalf_of?.key !== grant.self) continue;
            if (!following(grant.room) && !declined.has(agent.key)) follow(grant.room, agent.key);
          }
        };
        let followed = following(grant.room);
        const offFollowing = onFollow(grant.room, (key) => {
          if (followed && key === null && room.presence.everyone.some((person) => person.key === followed)) declined.add(followed);
          followed = key;
        });
        const draw = (): void => {
          followMine();
          layer.draw(pointing(room.awareness.peers, room.presence.everyone, grant.self));
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

export const Hooks = { IsshoPeople, IsshoPointers, IsshoMotion };
