// A form with shared components (editors, grids) in it publishes what the
// server accepted, not what a browser shows: on submit, the form waits.
// It stops the submit, locks its components, asks each to send what it has
// and to note the revision the server accepted in a field of its own, and
// then submits again, with those revisions. A component that cannot (it is
// offline, its access changed) stops the submit, with its reason.

/** A shared component in a form. */
export interface FormMember {
  /** Sends what it has and notes the accepted revision in its field; rejects with the reason it cannot. */
  flush(): Promise<unknown>;
  /** Locks (true) or unlocks (false) the component while the form waits. */
  lock(locked: boolean): void;
}

/** What the form holds: its members, and the submit it is waiting on. */
interface Barrier {
  members: Set<FormMember>;
  resubmit: boolean;
  busy: boolean;
  handler: (event: SubmitEvent) => void;
}

const barriers = new WeakMap<HTMLFormElement, Barrier>();

/**
 * Makes the form wait for the member on submit. Gives a function that
 * takes the member out (when the component goes). `failed` hears why a
 * submit could not go.
 */
export function holdForm(form: HTMLFormElement, member: FormMember, failed: (reason: string) => void = () => {}): () => void {
  let barrier = barriers.get(form);
  if (!barrier) {
    const shared: Barrier = { members: new Set(), resubmit: false, busy: false, handler: () => {} };
    shared.handler = (event: SubmitEvent): void => {
      if (shared.resubmit) {
        shared.resubmit = false;
        return;
      }
      event.preventDefault();
      event.stopImmediatePropagation();
      if (shared.busy) return;
      shared.busy = true;
      const members = [...shared.members];
      members.forEach((one) => one.lock(true));
      void Promise.all(members.map((one) => one.flush()))
        .then(() => {
          shared.resubmit = true;
          form.requestSubmit((event.submitter as HTMLButtonElement | HTMLInputElement | null) ?? undefined);
        })
        .catch((error: unknown) => failed(error instanceof Error ? error.message : "The form could not be saved"))
        .finally(() => {
          shared.busy = false;
          members.forEach((one) => one.lock(false));
        });
    };
    barriers.set(form, shared);
    form.addEventListener("submit", shared.handler, true);
    barrier = shared;
  }

  const shared = barrier;
  shared.members.add(member);
  return () => {
    shared.members.delete(member);
    if (shared.members.size === 0) {
      form.removeEventListener("submit", shared.handler, true);
      barriers.delete(form);
    }
  };
}
