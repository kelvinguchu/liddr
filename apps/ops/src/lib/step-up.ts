// High-risk actions need a fresh authenticator code. The API keeps the proof
// in a cookie the page cannot read, so this only tracks what the page needs:
// whether a code is being asked for, and until when the last one holds (for
// the top bar's chip). components/step-up-dialog renders the prompt.

import { useSyncExternalStore } from "react";

/** The person closed the prompt without confirming. Not an error to show. */
export class StepUpCancelled extends Error {
  constructor() {
    super("Confirmation cancelled.");
  }
}

interface State {
  expiresAt: number;
  asking: boolean;
}

let state: State = { expiresAt: 0, asking: false };
let waiting: { promise: Promise<void>; resolve: () => void; reject: (error: Error) => void } | null = null;
const listeners = new Set<() => void>();

function publish(next: Partial<State>) {
  state = { ...state, ...next };
  for (const listener of listeners) listener();
}

/** Opens the prompt, or joins the one already open. Resolves once confirmed. */
export function requestStepUp(): Promise<void> {
  if (!waiting) {
    let resolve!: () => void;
    let reject!: (error: Error) => void;
    const promise = new Promise<void>((res, rej) => {
      resolve = res;
      reject = rej;
    });
    waiting = { promise, resolve, reject };
    publish({ asking: true });
  }
  return waiting.promise;
}

/** Records a confirmation lasting seconds and lets the waiting action retry. */
export function stepUpConfirmed(seconds: number): void {
  publish({ expiresAt: Date.now() + seconds * 1000, asking: false });
  waiting?.resolve();
  waiting = null;
}

export function stepUpCancelled(): void {
  publish({ asking: false });
  waiting?.reject(new StepUpCancelled());
  waiting = null;
}

/** The session was replaced, and the proof belonged to the old one. */
export function stepUpEnded(): void {
  if (state.expiresAt !== 0) publish({ expiresAt: 0 });
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useStepUp(): State {
  return useSyncExternalStore(subscribe, () => state, () => state);
}
