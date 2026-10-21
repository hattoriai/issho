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
        const draw = (): void => drawPeople(this.el, someone(room.presence.everyone, room.awareness.peers, grant.self), { max, label });
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

const IsshoPointers = {
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
        const layer = pointerLayer(this.el, {
          share: this.el.dataset.share !== "false",
          aware: (changes) => room.aware(changes),
        });
        const draw = (): void => layer.draw(pointing(room.awareness.peers, room.presence.everyone, grant.self));
        const offPresence = room.presence.on(draw);
        const offAwareness = room.awareness.on(draw);
        this.stop = () => {
          offPresence();
          offAwareness();
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

export const Hooks = { IsshoPeople, IsshoPointers };
