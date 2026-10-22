import { test } from "node:test";
import assert from "node:assert/strict";
import { holdForm, type FormMember } from "../src/form";

// A form as far as the barrier knows it: submit listeners, and requestSubmit.
class FakeForm {
  listeners: ((event: SubmitEvent) => void)[] = [];
  submitted = 0;
  addEventListener(_type: string, listener: (event: SubmitEvent) => void): void { this.listeners.push(listener); }
  removeEventListener(_type: string, listener: (event: SubmitEvent) => void): void { this.listeners = this.listeners.filter((l) => l !== listener); }
  // A browser is firing a submit's events until the task that fired it ends, its microtasks
  // included: a requestSubmit then does nothing.
  firing = false;
  requestSubmit(): void { if (!this.firing) this.submit(); }
  submit(): { prevented: boolean } {
    const result = { prevented: false };
    const event = { submitter: null, preventDefault: () => { result.prevented = true; }, stopImmediatePropagation: () => {} } as unknown as SubmitEvent;
    for (const listener of this.listeners) listener(event);
    if (!result.prevented) this.submitted++;
    return result;
  }
  /** A person's click on the submit button: its submit is fired until its task ends. */
  click(): { prevented: boolean } {
    this.firing = true;
    setTimeout(() => { this.firing = false; }, 0);
    return this.submit();
  }
}

const tick = () => new Promise((resolve) => setImmediate(resolve));

function member(log: string[], name: string, flush: () => Promise<unknown> = async () => {}): FormMember {
  return { flush: async () => { log.push(`flush ${name}`); return flush(); }, lock: (locked) => log.push(`${locked ? "lock" : "unlock"} ${name}`) };
}

test("a submit waits for every member, locked, then goes once", async () => {
  const form = new FakeForm();
  const log: string[] = [];
  holdForm(form as unknown as HTMLFormElement, member(log, "a"));
  holdForm(form as unknown as HTMLFormElement, member(log, "b"));

  assert.equal(form.submit().prevented, true);
  await tick();
  await tick();
  assert.equal(form.submitted, 1);
  assert.deepEqual(log, ["lock a", "lock b", "flush a", "flush b", "unlock a", "unlock b"]);
});

test("a click goes, though no member has anything to send", async () => {
  const form = new FakeForm();
  holdForm(form as unknown as HTMLFormElement, member([], "a"));

  assert.equal(form.click().prevented, true);
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(form.submitted, 1);
});

test("a member that cannot stops the submit, with its reason", async () => {
  const form = new FakeForm();
  const reasons: string[] = [];
  holdForm(form as unknown as HTMLFormElement, member([], "a", async () => { throw new Error("Reconnect before saving this form"); }), (reason) => reasons.push(reason));
  form.submit();
  await tick();
  await tick();
  assert.equal(form.submitted, 0);
  assert.deepEqual(reasons, ["Reconnect before saving this form"]);
});

test("the last member to go takes the barrier away", () => {
  const form = new FakeForm();
  const leave = holdForm(form as unknown as HTMLFormElement, member([], "a"));
  assert.equal(form.listeners.length, 1);
  leave();
  assert.equal(form.listeners.length, 0);
  assert.equal(form.submit().prevented, false);
});
