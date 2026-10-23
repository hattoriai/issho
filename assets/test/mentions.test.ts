import { test } from "node:test";
import assert from "node:assert/strict";
import { finished, insertMention, matchCandidates, mentionQuery } from "../src/mentions";

test("the @ being typed: at the start or after a space, a name with single spaces", () => {
  assert.deepEqual(mentionQuery("@", 1), { start: 0, query: "" });
  assert.deepEqual(mentionQuery("Hi @Ad", 6), { start: 3, query: "Ad" });
  assert.deepEqual(mentionQuery("Hi @Ada Lo", 10), { start: 3, query: "Ada Lo" });
  assert.deepEqual(mentionQuery("one\n@k", 6), { start: 4, query: "k" });
  // Not in an address, nor across a line or two spaces, nor after the caret.
  assert.equal(mentionQuery("ada@example", 11), null);
  assert.equal(mentionQuery("@Ada\nhi", 7), null);
  assert.equal(mentionQuery("@Ada  then", 10), null);
  assert.equal(mentionQuery("no at here", 10), null);
});

test("candidates whose name or a word of it begins with the query, those here first", () => {
  const people = [
    { key: "user:ada", name: "Ada Lovelace", here: true },
    { key: "agent:claude", name: "Claude", kind: "agent", here: true },
    { key: "user:zoe", name: "Zoë Adams" },
    { key: "user:ken", name: "Ken" },
  ];
  assert.deepEqual(matchCandidates(people, "ad").map((one) => one.key), ["user:ada", "user:zoe"]);
  assert.deepEqual(matchCandidates(people, "ZOE").map((one) => one.key), ["user:zoe"]);
  assert.deepEqual(matchCandidates(people, "").map((one) => one.key), ["user:ada", "agent:claude", "user:ken", "user:zoe"]);
  assert.deepEqual(matchCandidates(people, "x"), []);
});

test("a pick replaces the query with the name, and the caret goes after it", () => {
  assert.deepEqual(insertMention("Hi @ad, look", 3, 6, "Ada Lovelace"), { text: "Hi @Ada Lovelace , look", caret: 17 });
});

test("a whole name and a space is a mention written: the list closes", () => {
  const people = [{ key: "user:grace", name: "Grace" }, { key: "user:ada", name: "Ada Lovelace" }];
  assert.equal(finished("Grace ", people), true);
  assert.equal(finished("ada lovelace ", people), true);
  assert.equal(finished("Grace", people), false);
  assert.equal(finished("Ada ", people), false);
});
