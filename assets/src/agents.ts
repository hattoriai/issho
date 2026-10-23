// The agents at work in a room, drawn: each one's task, its steps and how
// far it is, whom it works for, and Pause, Resume and Stop for those who
// may (Issho.Work). Issho.Components.agents/1 renders the element; its
// hook (IsshoAgents) draws into it with this.

import type { Peer } from "./awareness";
import { icon } from "./icons";
import type { Person } from "./presence";

export type TaskState = "working" | "paused" | "stopped" | "failed";
export type StepState = "pending" | "active" | "done" | "skipped";

/** An agent's task, as its state in the room says it. */
export interface Task {
  title: string;
  steps: { label: string; state: StepState }[];
  state: TaskState;
  note?: string;
  /** Who paused or stopped it. */
  by?: { key: string; name: string | null } | null;
}

/** An agent at work, as the bar shows it. */
export interface AtWork {
  agent: Person;
  task: Task;
  /** Whether this person may pause, resume or stop it: the one it acts for. */
  mine: boolean;
}

/** The agents of the room with a task, in the order they came; one entry each. */
export function atWork(peers: Peer[], everyone: Person[], self: string): AtWork[] {
  const tasks = new Map<string, Task>();
  for (const peer of peers) {
    const task = (peer.state as { task?: unknown }).task;
    if (isTask(task)) tasks.set(peer.key, task);
  }
  return everyone
    .filter((person) => tasks.has(person.key))
    .map((agent) => ({ agent, task: tasks.get(agent.key)!, mine: agent.on_behalf_of?.key === self }));
}

function isTask(task: unknown): task is Task {
  const one = task as Task | null;
  return !!one && typeof one === "object" && typeof one.title === "string" && Array.isArray(one.steps);
}

export interface AgentsOptions {
  /** Pause, Resume or Stop clicked for an agent. */
  interrupt: (agent: string, action: "pause" | "resume" | "stop") => void;
  /** Whether to offer them for agents that work for someone else (the policy decides): false. */
  anyone?: boolean;
  /** The bar's accessible name ("Agents at work"). */
  label?: string;
}

/**
 * Draws the agents at work into an element; hidden with none. An agent's
 * entry is drawn again only when it changed, so a frame of the room's
 * awareness takes no one's focus from a button, nor closes their steps.
 */
export function drawAgents(element: HTMLElement, agents: AtWork[], options: AgentsOptions): void {
  element.hidden = agents.length === 0;
  let list = element.querySelector<HTMLUListElement>(":scope > .issho-agents-list");
  if (!list) {
    list = document.createElement("ul");
    list.className = "issho-agents-list";
    element.replaceChildren(list);
  }
  list.setAttribute("aria-label", options.label ?? "Agents at work");

  const wanted = new Set(agents.map((one) => one.agent.key));
  for (const li of [...list.children] as HTMLLIElement[]) {
    if (!wanted.has(li.dataset.key ?? "")) li.remove();
  }
  let previous: HTMLLIElement | null = null;
  for (const one of agents) {
    const signature = JSON.stringify([one.agent.name, one.agent.color, one.agent.palette, one.agent.on_behalf_of?.name, one.task, one.mine || !!options.anyone]);
    let li = [...list.children].find((child) => (child as HTMLElement).dataset.key === one.agent.key) as HTMLLIElement | undefined;
    if (!li || li.dataset.signature !== signature) {
      const next = item(one, options);
      next.dataset.signature = signature;
      if (li) {
        // Its steps stay open or closed as the person left them, and its
        // focused button keeps the focus.
        const open = li.querySelector("details")?.open;
        if (open !== undefined) next.querySelector("details")?.toggleAttribute("open", open);
        const active = li.contains(document.activeElement) ? (document.activeElement as HTMLElement) : null;
        const again = active?.dataset.action ? `[data-action="${active.dataset.action}"]` : active?.tagName === "SUMMARY" ? "summary" : null;
        li.replaceWith(next);
        // A button gone with the change (Pause, once paused) gives the focus to the one in its place.
        if (again) (next.querySelector<HTMLElement>(again) ?? next.querySelector<HTMLElement>("[data-action]"))?.focus();
      } else {
        list.insertBefore(next, previous ? previous.nextSibling : list.firstChild);
      }
      li = next;
    }
    previous = li;
  }
}

function item({ agent, task, mine }: AtWork, options: AgentsOptions): HTMLLIElement {
  const li = document.createElement("li");
  li.className = "issho-agent";
  li.dataset.key = agent.key;
  li.dataset.state = task.state;
  li.style.setProperty("--issho-color", agent.color ?? `var(--issho-person-${agent.palette})`);
  const who = agent.name ?? agent.key;

  const row = document.createElement("div");
  row.className = "issho-agent-row";

  const avatar = document.createElement("span");
  avatar.className = "issho-agent-avatar";
  avatar.setAttribute("aria-hidden", "true");
  avatar.textContent = initials(who);

  const text = document.createElement("div");
  text.className = "issho-agent-text";
  const line = document.createElement("p");
  line.className = "issho-agent-line";
  const name = document.createElement("span");
  name.className = "issho-agent-name";
  name.textContent = who;
  line.append(name);
  if (agent.on_behalf_of) {
    const behalf = document.createElement("span");
    behalf.className = "issho-agent-for";
    behalf.textContent = `for ${agent.on_behalf_of.name ?? agent.on_behalf_of.key}`;
    line.append(behalf);
  }
  const title = document.createElement("p");
  title.className = "issho-agent-task";
  title.textContent = task.title;
  text.append(line, title);

  const state = document.createElement("span");
  state.className = "issho-agent-state";
  state.setAttribute("role", "status");
  state.textContent = stateWords(task);

  row.append(avatar, text, state);

  if (mine || options.anyone) {
    const actions = document.createElement("div");
    actions.className = "issho-agent-actions";
    const button = (action: "pause" | "resume" | "stop", words: string, shape: "pause" | "play" | "square"): HTMLButtonElement => {
      const one = document.createElement("button");
      one.type = "button";
      one.className = `issho-agent-button issho-agent-${action}`;
      one.dataset.action = action;
      one.title = `${words} ${who}`;
      one.setAttribute("aria-label", `${words} ${who}`);
      const label = document.createElement("span");
      label.textContent = words;
      one.append(icon(shape), label);
      one.addEventListener("click", () => options.interrupt(agent.key, action));
      return one;
    };
    if (task.state === "working") actions.append(button("pause", "Pause", "pause"), button("stop", "Stop", "square"));
    if (task.state === "paused") actions.append(button("resume", "Resume", "play"), button("stop", "Stop", "square"));
    if (task.state === "stopped") actions.append(button("resume", "Resume", "play"));
    row.append(actions);
  }
  li.append(row);

  if (task.steps.length > 0) {
    const done = task.steps.filter((step) => step.state === "done" || step.state === "skipped").length;
    const active = task.steps.findIndex((step) => step.state === "active");

    const details = document.createElement("details");
    details.className = "issho-agent-details";
    const summary = document.createElement("summary");
    summary.className = "issho-agent-summary";
    const meter = document.createElement("span");
    meter.className = "issho-agent-meter";
    meter.setAttribute("role", "progressbar");
    meter.setAttribute("aria-label", `${task.title}: steps done`);
    meter.setAttribute("aria-valuemin", "0");
    meter.setAttribute("aria-valuemax", String(task.steps.length));
    meter.setAttribute("aria-valuenow", String(done));
    const fill = document.createElement("span");
    fill.style.width = `${Math.round((done / task.steps.length) * 100)}%`;
    meter.append(fill);
    const where = document.createElement("span");
    where.className = "issho-agent-progress";
    where.textContent =
      active >= 0 ? `Step ${active + 1} of ${task.steps.length} · ${task.steps[active].label}` : `${done} of ${task.steps.length} steps`;
    summary.append(meter, where, icon("chevron-down", "issho-icon issho-agent-chevron"));

    const steps = document.createElement("ol");
    steps.className = "issho-agent-steps";
    for (const step of task.steps) {
      const one = document.createElement("li");
      one.dataset.state = step.state;
      if (step.state === "active") one.setAttribute("aria-current", "step");
      const label = document.createElement("span");
      label.textContent = step.label;
      one.append(stepIcon(step.state), label);
      steps.append(one);
    }
    details.append(summary, steps);
    li.append(details);
  }

  if (task.note) {
    const note = document.createElement("p");
    note.className = "issho-agent-note";
    note.textContent = task.note;
    li.append(note);
  }
  return li;
}

function stepIcon(state: StepState): Element {
  if (state === "done") return icon("check");
  if (state === "skipped") return icon("minus");
  if (state === "active") {
    const dot = document.createElement("span");
    dot.className = "issho-agent-step-dot";
    dot.setAttribute("aria-hidden", "true");
    return dot;
  }
  return icon("circle");
}

function initials(name: string): string {
  return name
    .split(/[\s:_-]+/u)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0])
    .join("")
    .toUpperCase();
}

function stateWords(task: Task): string {
  const by = task.by ? ` by ${task.by.name ?? task.by.key}` : "";
  if (task.state === "paused") return `Paused${by}`;
  if (task.state === "stopped") return `Stopped${by}`;
  if (task.state === "failed") return "Failed";
  return "Working";
}
