// Stops the same request being sent twice at once. While a call is running, anyone asking for it again (a second tap,
// a screen that gained focus twice) gets the same answer back instead of starting another call.
export function singleFlight<A extends unknown[], T>(fn: (...args: A) => Promise<T>): (...args: A) => Promise<T> {
  let running: Promise<T> | null = null;
  return (...args: A) => {
    if (running) return running;
    const p = fn(...args).finally(() => {
      running = null;
    });
    running = p;
    return p;
  };
}

// For actions that change something (send, close, upload): while one is running, a second press is ignored.
// Returns undefined when it was ignored, so the caller can tell.
export function exclusive<A extends unknown[], T>(fn: (...args: A) => Promise<T>): (...args: A) => Promise<T | undefined> {
  let busy = false;
  return async (...args: A) => {
    if (busy) return undefined;
    busy = true;
    try {
      return await fn(...args);
    } finally {
      busy = false;
    }
  };
}
