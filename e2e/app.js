// The page's script: LiveView with Issho's hooks, and a block of the page
// that says where its places are (locate) and which is under a pointer
// (point): an item of the list, and where in it.
import { Socket } from "phoenix";
import { LiveSocket } from "../deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js";
import { Hooks, holdForm, locate, point } from "../assets/src/index";

const E2EList = {
  mounted() {
    const item = (n) => this.el.querySelector(`li[data-item="${n}"]`);
    this.off = [
      locate(this.el, (at) => (Array.isArray(at?.path) ? item(at.path[1])?.getBoundingClientRect() ?? null : null)),
      point(this.el, (x, y) => {
        const li = document.elementFromPoint(x, y)?.closest("li[data-item]");
        if (!li || !this.el.contains(li)) return null;
        const box = li.getBoundingClientRect();
        const round = (value) => Math.round(Math.min(1, Math.max(0, value)) * 100) / 100;
        return { path: ["item", li.dataset.item], x: round((x - box.left) / box.width), y: round((y - box.top) / box.height) };
      }),
    ];
  },
  destroyed() {
    for (const off of this.off) off();
  },
};

// A shared component in a form, with nothing to send: its form waits for it all the same.
const E2EForm = {
  mounted() {
    this.leave = holdForm(this.el.closest("form"), { flush: async () => {}, lock: () => {} });
  },
  destroyed() {
    this.leave();
  },
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, { params: { _csrf_token: csrfToken }, hooks: { ...Hooks, E2EList, E2EForm } });
liveSocket.connect();
window.liveSocket = liveSocket;
