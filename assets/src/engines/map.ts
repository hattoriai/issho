// The twin of Issho.Engine.Map: values at paths, in the order the authority
// accepts them. Every case of test/corpus/engine_map.json gives the same
// result here and on the server.

import type { Applied, Engine, Json, Operation, State } from "../engine";

const MAX_PATH = 16;
const MAX_DEPTH = 32;
const encoder = new TextEncoder();

type Result = { ok: true; value: State } | { ok: false; reason: string };

export const mapEngine: Engine = {
  name: "map",
  version: 1,
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
function apply(state: State, op: Operation): Result {
  if (!("path" in op)) return fail("invalid_operation");
  switch (op["op"]) {
    case "set": {
      if (!("value" in op)) return fail("invalid_operation");
      const path = checkPath(op["path"]);
      if (!path) return fail("invalid_path");
      if (!isJson(op["value"], MAX_DEPTH)) return fail("invalid_value");
      return put(state, path, op["value"] as Json);
    }
    case "delete": {
      const path = checkPath(op["path"]);
      if (!path) return fail("invalid_path");
      return { ok: true, value: remove(state, path) };
    }
    case "increment": {
      const by = op["by"];
      if (typeof by !== "number") return fail("invalid_operation");
      const path = checkPath(op["path"]);
      if (!path) return fail("invalid_path");
      const found = get(state, path);
      if (found === "through_value") return fail("invalid_path");
      if (found === undefined || found === null) return put(state, path, by);
      if (typeof found !== "number") return fail("not_a_number");
      return put(state, path, found + by);
    }
    default:
      return fail("invalid_operation");
  }
}

function fail(reason: string): { ok: false; reason: string } {
  return { ok: false, reason };
}

function checkPath(path: Json | undefined): string[] | null {
  if (!Array.isArray(path) || path.length === 0 || path.length > MAX_PATH) return null;
  for (const key of path) {
    if (typeof key !== "string") return null;
    const bytes = encoder.encode(key).length;
    if (bytes < 1 || bytes > 256) return null;
  }
  return path as string[];
}

function isObject(value: Json | undefined): value is { [key: string]: Json } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// The value at a path; "through_value" when the path goes through a value
// that is not a map (the server refuses that).
function get(state: State, path: string[]): Json | undefined | "through_value" {
  let current: Json | undefined = state;
  for (const key of path) {
    if (current === undefined || current === null) return undefined;
    if (!isObject(current)) return "through_value";
    current = Object.prototype.hasOwnProperty.call(current, key) ? current[key] : undefined;
  }
  return current;
}

function put(map: State, path: string[], value: Json): Result {
  const [key, ...rest] = path;
  if (rest.length === 0) return { ok: true, value: { ...map, [key]: value } };
  const child = Object.prototype.hasOwnProperty.call(map, key) ? map[key] : {};
  if (!isObject(child)) return fail("invalid_path");
  const next = put(child, rest, value);
  return next.ok ? { ok: true, value: { ...map, [key]: next.value } } : next;
}

function remove(map: State, path: string[]): State {
  const [key, ...rest] = path;
  if (!Object.prototype.hasOwnProperty.call(map, key)) return map;
  if (rest.length === 0) {
    const copy = { ...map };
    delete copy[key];
    return copy;
  }
  const child = map[key];
  return isObject(child) ? { ...map, [key]: remove(child, rest) } : map;
}

function isJson(value: unknown, depth: number): boolean {
  if (depth < 0) return false;
  if (value === null || typeof value === "string" || typeof value === "boolean") return true;
  if (typeof value === "number") return Number.isFinite(value);
  if (Array.isArray(value)) return value.every((item) => isJson(item, depth - 1));
  if (typeof value === "object") return Object.values(value as object).every((item) => isJson(item, depth - 1));
  return false;
}
