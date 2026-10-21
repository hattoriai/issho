// Undo across a page: each component keeps its own steps (a text's inverse
// operations, a grid's cell edits), and the page keeps their order, so that
// undo takes back the person's last change wherever they made it, as in a
// document of blocks, and redo puts it back.
//
// A component records each new step it makes (`record`), not the changes it
// merges into its last step (a word typed in one go). The page's undo asks
// the component of the last step to take its own last step back, which it
// does as a change of its own (an inverse transaction), so the others see it.

/** A component with undo steps of its own. */
export interface HistoryOwner {
  /** Takes back the component's last step; false when it has none left. */
  undo(): boolean;
  /** Puts back the component's last undone step; false when it has none. */
  redo(): boolean;
  /** Forgets the steps it could redo: a new change was made somewhere on the page. */
  clearRedo?(): void;
}

export class PageHistory {
  private done: HistoryOwner[] = [];
  private undone: HistoryOwner[] = [];
  private listeners = new Set<() => void>();

  /** A new step of the owner's: the page's redo steps are gone. */
  record(owner: HistoryOwner): void {
    this.done.push(owner);
    for (const other of new Set(this.undone)) if (other !== owner) other.clearRedo?.();
    this.undone = [];
    this.emit();
  }

  /** Takes back the last step made on the page; false when there is none. */
  undo(): boolean {
    while (this.done.length > 0) {
      const owner = this.done.pop()!;
      if (owner.undo()) {
        this.undone.push(owner);
        this.emit();
        return true;
      }
    }
    this.emit();
    return false;
  }

  /** Puts back the last step undone on the page; false when there is none. */
  redo(): boolean {
    while (this.undone.length > 0) {
      const owner = this.undone.pop()!;
      if (owner.redo()) {
        this.done.push(owner);
        this.emit();
        return true;
      }
    }
    this.emit();
    return false;
  }

  get canUndo(): boolean {
    return this.done.length > 0;
  }

  get canRedo(): boolean {
    return this.undone.length > 0;
  }

  /** Takes a component's steps out (it left the page). */
  forget(owner: HistoryOwner): void {
    this.done = this.done.filter((one) => one !== owner);
    this.undone = this.undone.filter((one) => one !== owner);
    this.emit();
  }

  /** Called whenever what can be undone or redone may have changed. */
  on(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private emit(): void {
    for (const listener of this.listeners) listener();
  }
}

/** The page's history, shared by its components. */
export const pageHistory = new PageHistory();
