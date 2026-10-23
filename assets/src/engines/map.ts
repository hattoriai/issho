// The twin of Issho.Engine.Map: values at paths, and lists of items by
// their id, in the order the authority accepts them. Every case of
// test/corpus/engine_map.json gives the same result here and on the server.

import type { Applied, Engine, Json, Operation, State } from "../engine";

const MAX_PATH = 16;
const MAX_DEPTH = 32;
const encoder = new TextEncoder();

type JsonMap = { [key: string]: Json };
type Result<T = Json> = { ok: true; value: T } | { ok: false; reason: string };
type Where = { kind: "start" } | { kind: "end" } | { kind: "after" | "before"; id: string };
// The value at a path, `gone` through an item that is gone, or a failure.
type Found = { ok: true; value: Json | undefined } | { ok: false; reason: string } | "gone";

export const mapEngine: Engine = {
  name: "map",
  version: 2,
  apply(state: State, ops: Operation[]): Applied {
    let current = state;
    for (const op of ops) {
      const result = apply(current, op);
      if (!result.ok) return result;
      current = result.value;
    }
    return { ok: true, state: current };
  },
};

// An operation without the keys of its kind is an invalid operation, as
// on the server, where it matches no clause.
function apply(state: State, op: Operation): Result<State> {
  if (!("path" in op)) return fail("invalid_operation");
  switch (op["op"]) {
    case "set": {
      if (!("value" in op)) return fail("invalid_operation");
      const path = checkPath(op["path"]);
      if (!path) return fail("invalid_path");
      if (!isJson(op["value"], MAX_DEPTH)) return fail("invalid_value");
      const value = op["value"] as Json;
      return asState(update(state, path, () => ({ ok: true, value })));
    }
    case "delete": {
      const path = checkPath(op["path"]);
      if (!path) return fail("invalid_path");
      return { ok: true, value: remove(state, path) as State };
    }
    case "increment": {
      const by = op["by"];
      if (typeof by !== "number") return fail("invalid_operation");
      const path = checkPath(op["path"]);
      if (!path) return fail("invalid_path");
      return asState(
        update(state, path, (current) => {
          if (current === undefined || current === null) return { ok: true, value: by };
          if (typeof current !== "number") return fail("not_a_number");
          return { ok: true, value: current + by };
        }),
      );
    }
    case "insert": {
      if (!("value" in op)) return fail("invalid_operation");
      const path = checkPath(op["path"]);
      if (!path) return fail("invalid_path");
      const item = op["value"];
      const checked = checkItem(item);
      if (!checked.ok) return checked;
      const where = whereOf(op);
      if (!where) return fail("invalid_operation");
      return asState(update(state, path, (current) => insert(current, item as JsonMap, where)));
    }
    case "move": {
      if (!("id" in op)) return fail("invalid_operation");
      const path = checkPath(op["path"]);
      const to = checkPath("to" in op ? op["to"] : op["path"]);
      if (!path || !to) return fail("invalid_path");
      const id = op["id"];
      if (!isKey(id)) return fail("invalid_id");
      const where = whereOf(op);
      if (!where) return fail("invalid_operation");
      return move(state, path, id, to, where);
    }
    default:
      return fail("invalid_operation");
  }
}

function fail(reason: string): { ok: false; reason: string } {
  return { ok: false, reason };
}

function asState(result: Result): Result<State> {
  return result as Result<State>;
}

function whereOf(op: Operation): Where | null {
  if (typeof op["after"] === "string") return { kind: "after", id: op["after"] };
  if (typeof op["before"] === "string") return { kind: "before", id: op["before"] };
  if (op["at"] === "start") return { kind: "start" };
  if (op["at"] === "end") return { kind: "end" };
  if ("after" in op || "before" in op || "at" in op) return null;
  return { kind: "end" };
}

function isKey(key: Json | undefined): key is string {
  if (typeof key !== "string") return false;
  const bytes = encoder.encode(key).length;
  return bytes >= 1 && bytes <= 256;
}

function checkPath(path: Json | undefined): string[] | null {
  if (!Array.isArray(path) || path.length === 0 || path.length > MAX_PATH) return null;
  return path.every(isKey) ? (path as string[]) : null;
}

function checkItem(item: Json | undefined): Result<null> {
  if (!isObject(item) || !has(item, "id")) return fail("invalid_value");
  if (!isKey(item["id"])) return fail("invalid_id");
  if (!isJson(item, MAX_DEPTH)) return fail("invalid_value");
  return { ok: true, value: null };
}

function isObject(value: Json | undefined): value is JsonMap {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function has(map: JsonMap, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(map, key);
}

function isItem(value: Json, id: string): boolean {
  return isObject(value) && has(value, "id") && value["id"] === id;
}

// A list of items, each a map with an id: through a list of other values
// ([1, 2]) there is no path.
function isItems(list: Json[]): boolean {
  return list.every((value) => isObject(value) && has(value, "id") && typeof value["id"] === "string");
}

function indexOf(list: Json[], id: string): number {
  return list.findIndex((value) => isItem(value, id));
}

// The value at a path given to `fun` (undefined when missing), and what it
// gives put there. Through a map, the maps on the way are made; through a
// list, an item that is gone leaves the state as it is.
function update(value: Json, path: string[], fun: (current: Json | undefined) => Result): Result {
  const [key, ...rest] = path;
  if (isObject(value)) {
    if (rest.length === 0) {
      const next = fun(has(value, key) ? value[key] : undefined);
      return next.ok ? { ok: true, value: { ...value, [key]: next.value } } : next;
    }
    const child = has(value, key) ? value[key] : {};
    if (!isObject(child) && !Array.isArray(child)) return fail("invalid_path");
    const next = update(child, rest, fun);
    return next.ok ? { ok: true, value: { ...value, [key]: next.value } } : next;
  }
  if (Array.isArray(value)) {
    const at = indexOf(value, key);
    if (at < 0) return isItems(value) ? { ok: true, value } : fail("invalid_path");
    const item = value[at];
    let next: Result;
    if (rest.length === 0) {
      // An item set whole keeps its id.
      const whole = fun(item);
      if (!whole.ok) return whole;
      if (!isObject(whole.value)) return fail("invalid_value");
      next = { ok: true, value: { ...whole.value, id: key } };
    } else {
      next = update(item, rest, fun);
    }
    if (!next.ok) return next;
    const copy = [...value];
    copy[at] = next.value;
    return { ok: true, value: copy };
  }
  return fail("invalid_path");
}

function remove(value: Json, path: string[]): Json {
  const [key, ...rest] = path;
  if (isObject(value)) {
    if (!has(value, key)) return value;
    if (rest.length === 0) {
      const copy = { ...value };
      delete copy[key];
      return copy;
    }
    const child = value[key];
    return isObject(child) || Array.isArray(child) ? { ...value, [key]: remove(child, rest) } : value;
  }
  if (Array.isArray(value)) {
    if (rest.length === 0) return value.filter((item) => !isItem(item, key));
    const at = indexOf(value, key);
    if (at < 0) return value;
    const copy = [...value];
    copy[at] = remove(value[at], rest);
    return copy;
  }
  return value;
}

function insert(current: Json | undefined, item: JsonMap, where: Where): Result {
  const list = current === undefined || current === null ? [] : current;
  if (!Array.isArray(list)) return fail("not_a_list");
  if (indexOf(list, item["id"] as string) >= 0) return fail("duplicate_id");
  return { ok: true, value: place(list, item, where) };
}

// The item at its place in the list; after or before an item that is gone,
// at the end.
function place(list: Json[], item: JsonMap, where: Where): Json[] {
  if (where.kind === "start") return [item, ...list];
  if (where.kind === "end") return [...list, item];
  const at = indexOf(list, where.id);
  if (at < 0) return [...list, item];
  const copy = [...list];
  copy.splice(where.kind === "after" ? at + 1 : at, 0, item);
  return copy;
}

// An item that is gone, or a list to go to through an item that is gone,
// leaves the state as it is.
function move(state: State, path: string[], id: string, to: string[], where: Where): Result<State> {
  if ((where.kind === "after" || where.kind === "before") && where.id === id) return { ok: true, value: state };
  const from = get(state, path);
  if (from === "gone") return { ok: true, value: state };
  if (!from.ok) return from;
  if (from.value === undefined || from.value === null) return { ok: true, value: state };
  if (!Array.isArray(from.value)) return fail("not_a_list");
  const item = from.value.find((value) => isItem(value, id));
  if (item === undefined) return { ok: true, value: state };
  const target = get(state, to);
  if (target === "gone") return { ok: true, value: state };
  if (!target.ok) return target;
  // Out of its list, then into the other: a move within one list finds the
  // list without it.
  const without = update(state, path, (list) => ({ ok: true, value: (list as Json[]).filter((value) => !isItem(value, id)) }));
  if (!without.ok) return without;
  return asState(update(without.value, to, (current) => insert(current, item as JsonMap, where)));
}

function get(value: Json | undefined, path: string[]): Found {
  if (path.length === 0) return { ok: true, value };
  const [key, ...rest] = path;
  if (value === undefined || value === null) return { ok: true, value: undefined };
  if (isObject(value)) return get(has(value, key) ? value[key] : undefined, rest);
  if (Array.isArray(value)) {
    const at = indexOf(value, key);
    if (at < 0) return isItems(value) ? "gone" : fail("invalid_path");
    return get(value[at], rest);
  }
  return fail("invalid_path");
}

function isJson(value: unknown, depth: number): boolean {
  if (depth < 0) return false;
  if (value === null || typeof value === "string" || typeof value === "boolean") return true;
  if (typeof value === "number") return Number.isFinite(value);
  if (Array.isArray(value)) return value.every((item) => isJson(item, depth - 1));
  if (typeof value === "object") return Object.values(value as object).every((item) => isJson(item, depth - 1));
  return false;
}
