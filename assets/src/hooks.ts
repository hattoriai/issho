// Issho's LiveView hooks, for the LiveSocket's hooks:
//
//     import { Hooks as IsshoHooks } from "issho"
//     new LiveSocket("/live", Socket, { hooks: { ...IsshoHooks, ...yours } })
//
// IsshoPeople draws the people of the room of its grant
// (Issho.Components.people/1), live.

import { requestGrant, type Grant, type LiveHook } from "./grant";
import { joinRoom, releaseRoom } from "./page";
import { drawPeople, someone } from "./people";

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
    this.room = grant.room;
    void joinRoom(grant.room, {
      token: grant.token,
      self: grant.self,
      socket: grant.socket,
      maxChannels: grant.max_channels,
      renew: async () => (await requestGrant(this, grant.room)).token,
    }).then(
      (room) => {
        const draw = (): void => drawPeople(this.el, someone(room.presence.everyone, room.awareness.peers, grant.self), { max });
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

export const Hooks = { IsshoPeople };
