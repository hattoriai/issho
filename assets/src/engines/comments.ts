// The twin of Issho.Engine.Comments: a room's threads of comments. Every
// case of test/corpus/engine_comments.json gives the same result here and
// on the server.

import type { Applied, Engine, Json, Operation, State } from "../engine";

const MAX_BODY = 20_000;
const MAX_MENTIONS = 50;
const MAX_EMOJI = 32;
const MAX_REACTIONS = 50;
const MAX_PLACE = 4_096;
const MAX_AUTHOR = 2_048;
const TIME = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{1,6})?Z$/;
const encoder = new TextEncoder();

type JsonMap = { [key: string]: Json };
type Result<T> = { ok: true; value: T } | { ok: false; reason: string };

/** A comment of a thread, as the comments document keeps it. */
export interface Comment {
  id: string;
  author: { key: string; name: string | null; kind?: string; avatar?: string | null; color?: string | null; on_behalf_of?: { key: string; name: string | null } | null };
  body: string;
  mentions: string[];
  at: string;
  edited: string | null;
  reactions: { [emoji: string]: string[] };
}

/** A thread of comments, at a place of a component or of the page. */
export interface Thread {
  id: string;
  place: { doc: string; at?: Json } | null;
  status: "open" | "resolved";
  resolved: { by: string; at: string } | null;
  comments: Comment[];
}

export const commentsEngine: Engine = {
  name: "issho.comments",
  version: 1,
  apply(state: State, ops: Operation[], author: string): Applied {
    let current = state;
    for (const op of ops) {
      const result = apply(current, op, author);
      if (!result.ok) return result;
      current = result.value;
    }
    return { ok: true, state: current };
  },
};

function fail(reason: string): { ok: false; reason: string } {
  return { ok: false, reason };
}

function threadsOf(state: State): JsonMap[] {
  return (Array.isArray(state["threads"]) ? state["threads"] : []) as JsonMap[];
}

function has(map: Operation | JsonMap, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(map, key);
}

function apply(state: State, op: Operation, author: string): Result<State> {
  const kind = op["op"];
  if (!has(op, "thread")) return fail("invalid_operation");
  const id = op["thread"] as Json;
  switch (kind) {
    case "start": {
      if (!has(op, "place") || !has(op, "comment")) return fail("invalid_operation");
      if (!isId(id)) return fail("invalid_id");
      const place = checkPlace(op["place"]);
      if (!place.ok) return place;
      const comment = newComment(op["comment"], author);
      if (!comment.ok) return comment;
      const threads = threadsOf(state);
      if (threads.some((thread) => thread["id"] === id)) return fail("duplicate_id");
      const thread: JsonMap = { id, place: op["place"] as Json, status: "open", resolved: null, comments: [comment.value] };
      return { ok: true, value: { ...state, threads: [...threads, thread] } };
    }
    case "reply": {
      if (!has(op, "comment")) return fail("invalid_operation");
      const comment = newComment(op["comment"], author);
      if (!comment.ok) return comment;
      return thread(state, id, (found) => {
        const comments = found["comments"] as JsonMap[];
        if (comments.some((one) => one["id"] === comment.value["id"])) return fail("duplicate_id");
        return { ok: true, value: { ...found, comments: [...comments, comment.value] } };
      });
    }
    case "edit": {
      if (!has(op, "comment")) return fail("invalid_operation");
      const body = op["body"];
      const mentions = op["mentions"];
      if (!isBody(body)) return fail("invalid_body");
      if (!isMentions(mentions)) return fail("invalid_mentions");
      if (!isTime(op["at"])) return fail("invalid_time");
      return comment(state, id, op["comment"] as Json, (found) =>
        isOwn(found, author) ? { ok: true, value: { ...found, body, mentions, edited: op["at"] as Json } } : fail("not_the_author"),
      );
    }
    case "delete": {
      if (!has(op, "comment")) return fail("invalid_operation");
      const cid = op["comment"] as Json;
      const next = thread(state, id, (found) => {
        const comments = found["comments"] as JsonMap[];
        const one = comments.find((c) => c["id"] === cid);
        if (!one) return { ok: true, value: found };
        if (!isOwn(one, author)) return fail("not_the_author");
        return { ok: true, value: { ...found, comments: comments.filter((c) => c["id"] !== cid) } };
      });
      if (!next.ok) return next;
      // A thread with no comment left goes.
      return { ok: true, value: { ...next.value, threads: threadsOf(next.value).filter((t) => (t["comments"] as Json[]).length > 0) } };
    }
    case "react":
    case "unreact": {
      if (!has(op, "comment") || !has(op, "emoji")) return fail("invalid_operation");
      const emoji = op["emoji"];
      if (typeof emoji !== "string" || bytes(emoji) < 1 || bytes(emoji) > MAX_EMOJI) return fail("invalid_emoji");
      if (typeof author !== "string") return fail("no_author");
      return comment(state, id, op["comment"] as Json, (found) => {
        const reactions = found["reactions"] as { [emoji: string]: string[] };
        const keys = has(reactions, emoji) ? reactions[emoji] : [];
        if (kind === "unreact") {
          const rest = keys.filter((key) => key !== author);
          const copy = { ...reactions };
          if (rest.length === 0) delete copy[emoji];
          else copy[emoji] = rest;
          return { ok: true, value: { ...found, reactions: copy } };
        }
        if (keys.includes(author)) return { ok: true, value: found };
        if (!has(reactions, emoji) && Object.keys(reactions).length >= MAX_REACTIONS) return fail("too_many_reactions");
        return { ok: true, value: { ...found, reactions: { ...reactions, [emoji]: [...keys, author] } } };
      });
    }
    case "resolve": {
      if (!has(op, "at")) return fail("invalid_operation");
      if (!isTime(op["at"])) return fail("invalid_time");
      if (typeof author !== "string") return fail("no_author");
      return thread(state, id, (found) =>
        found["status"] === "resolved"
          ? { ok: true, value: found }
          : { ok: true, value: { ...found, status: "resolved", resolved: { by: author, at: op["at"] as Json } } },
      );
    }
    case "reopen":
      return thread(state, id, (found) => ({ ok: true, value: { ...found, status: "open", resolved: null } }));
    case "place": {
      if (!has(op, "place")) return fail("invalid_operation");
      const place = checkPlace(op["place"]);
      if (!place.ok) return place;
      return thread(state, id, (found) => ({ ok: true, value: { ...found, place: op["place"] as Json } }));
    }
    default:
      return fail("invalid_operation");
  }
}

// A thread changed by `fun`; one that is gone, the state as it is.
function thread(state: State, id: Json, fun: (thread: JsonMap) => Result<JsonMap>): Result<State> {
  const threads = threadsOf(state);
  const at = threads.findIndex((one) => one["id"] === id);
  if (at < 0) return { ok: true, value: state };
  const next = fun(threads[at]);
  if (!next.ok) return next;
  const copy = [...threads];
  copy[at] = next.value;
  return { ok: true, value: { ...state, threads: copy } };
}

function comment(state: State, id: Json, cid: Json, fun: (comment: JsonMap) => Result<JsonMap>): Result<State> {
  return thread(state, id, (found) => {
    const comments = found["comments"] as JsonMap[];
    const at = comments.findIndex((one) => one["id"] === cid);
    if (at < 0) return { ok: true, value: found };
    const next = fun(comments[at]);
    if (!next.ok) return next;
    const copy = [...comments];
    copy[at] = next.value;
    return { ok: true, value: { ...found, comments: copy } };
  });
}

function newComment(value: Json | undefined, author: string): Result<JsonMap> {
  if (!isObject(value) || !has(value, "id") || !has(value, "author") || !has(value, "body") || !has(value, "at")) return fail("invalid_comment");
  const mentions = has(value, "mentions") ? value["mentions"] : [];
  if (!isId(value["id"])) return fail("invalid_id");
  const who = value["author"];
  if (!isObject(who) || typeof who["key"] !== "string" || who["key"] !== author || !has(who, "name")) return fail("not_the_author");
  if (who["name"] !== null && typeof who["name"] !== "string") return fail("not_the_author");
  if (jsonSize(who) > MAX_AUTHOR) return fail("invalid_author");
  if (!isBody(value["body"])) return fail("invalid_body");
  if (!isMentions(mentions)) return fail("invalid_mentions");
  if (!isTime(value["at"])) return fail("invalid_time");
  return {
    ok: true,
    value: { id: value["id"], author: who, body: value["body"], mentions, at: value["at"], edited: null, reactions: {} },
  };
}

function isObject(value: Json | undefined): value is JsonMap {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function bytes(text: string): number {
  return encoder.encode(text).length;
}

function isId(id: Json | undefined): id is string {
  return typeof id === "string" && bytes(id) >= 1 && bytes(id) <= 64;
}

function isBody(body: Json | undefined): body is string {
  return typeof body === "string" && body.trim() !== "" && bytes(body) <= MAX_BODY;
}

function isMentions(mentions: Json | undefined): mentions is string[] {
  return (
    Array.isArray(mentions) &&
    mentions.length <= MAX_MENTIONS &&
    mentions.every((key) => typeof key === "string" && bytes(key) >= 1 && bytes(key) <= 256)
  );
}

// A time as ISO 8601, in UTC, to the second or finer, of a real day.
function isTime(at: Json | undefined): boolean {
  if (typeof at !== "string") return false;
  const match = TIME.exec(at);
  if (!match) return false;
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
  if (month < 1 || month > 12 || hour > 23 || minute > 59 || second > 59) return false;
  const days = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return day >= 1 && day <= days;
}

function checkPlace(place: Json | undefined): Result<null> {
  if (place === null) return { ok: true, value: null };
  if (!isObject(place) || typeof place["doc"] !== "string" || jsonSize(place) > MAX_PLACE) return fail("invalid_place");
  return { ok: true, value: null };
}

function isOwn(comment: JsonMap, author: string): boolean {
  const who = comment["author"];
  return isObject(who) && typeof who["key"] === "string" && who["key"] === author;
}

function jsonSize(value: Json): number {
  return bytes(JSON.stringify(value));
}
