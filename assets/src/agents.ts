// The agents at work in a room, drawn: each one's task, its steps and how
// far it is, whom it works for, and Pause, Resume and Stop for those who
// may (Issho.Work). Issho.Components.agents/1 renders the element; its
// hook (IsshoAgents) draws into it with this.

import type { Peer } from "./awareness";
import type { Person } from "./presence";

export type TaskState = "working" | "paused" | "stopped";
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

/** Draws the agents at work into an element, replacing what it held; hidden with none. */
export function drawAgents(element: HTMLElement, agents: AtWork[], options: AgentsOptions): void {
  element.hidden = agents.length === 0;
  const list = document.createElement("ul");
  list.className = "issho-agents-list";
  list.setAttribute("aria-label", options.label ?? "Agents at work");
  for (const one of agents) list.append(item(one, options));
  element.replaceChildren(list);
}

function item({ agent, task, mine }: AtWork, options: AgentsOptions): HTMLLIElement {
  const li = document.createElement("li");
  li.className = "issho-agent";
  li.dataset.key = agent.key;
  li.dataset.state = task.state;
  li.style.setProperty("--issho-color", agent.color ?? `var(--issho-person-${agent.palette})`);

  const head = document.createElement("p");
  head.className = "issho-agent-head";
  const name = document.createElement("span");
  name.className = "issho-agent-name";
  name.textContent = agent.name ?? agent.key;
  head.append(name);
  if (agent.on_behalf_of) {
    const behalf = document.createElement("span");
    behalf.className = "issho-agent-for";
    behalf.textContent = `for ${agent.on_behalf_of.name ?? agent.on_behalf_of.key}`;
    head.append(behalf);
  }
  const title = document.createElement("span");
  title.className = "issho-agent-task";
  title.textContent = task.title;
  head.append(title);

  const done = task.steps.filter((step) => step.state === "done" || step.state === "skipped").length;
  if (task.steps.length > 0) {
    const progress = document.createElement("span");
    progress.className = "issho-agent-progress";
    progress.textContent = `${done} of ${task.steps.length}`;
    head.append(progress);
  }

  const state = document.createElement("span");
  state.className = "issho-agent-state";
  state.setAttribute("role", "status");
  state.textContent = stateWords(task);
  head.append(state);
  li.append(head);

  if (task.steps.length > 0) {
    const steps = document.createElement("ol");
    steps.className = "issho-agent-steps";
    for (const step of task.steps) {
      const one = document.createElement("li");
      one.dataset.state = step.state;
      one.textContent = step.label;
      if (step.state === "active") one.setAttribute("aria-current", "step");
      steps.append(one);
    }
    li.append(steps);
  }

  if (task.note) {
    const note = document.createElement("p");
    note.className = "issho-agent-note";
    note.textContent = task.note;
    li.append(note);
  }

  if (mine || options.anyone) {
    const actions = document.createElement("p");
    actions.className = "issho-agent-actions";
    const who = agent.name ?? agent.key;
    const button = (action: "pause" | "resume" | "stop", words: string): HTMLButtonElement => {
      const one = document.createElement("button");
      one.type = "button";
      one.dataset.action = action;
      one.textContent = words;
      one.setAttribute("aria-label", `${words} ${who}`);
      one.addEventListener("click", () => options.interrupt(agent.key, action));
      return one;
    };
    if (task.state === "working") actions.append(button("pause", "Pause"), button("stop", "Stop"));
    if (task.state === "paused") actions.append(button("resume", "Resume"), button("stop", "Stop"));
    if (task.state === "stopped") actions.append(button("resume", "Resume"));
    li.append(actions);
  }
  return li;
}

function stateWords(task: Task): string {
  const by = task.by ? ` by ${task.by.name ?? task.by.key}` : "";
  if (task.state === "paused") return `Paused${by}`;
  if (task.state === "stopped") return `Stopped${by}`;
  return "Working";
}
