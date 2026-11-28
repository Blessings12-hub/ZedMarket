// What the app tells the team when it crashes. Pure helpers, so they can be tested without a phone.
// Nothing personal is sent: only the error text, where in the app it happened, and the kind of device.

export type ErrorReport = { message: string; stack: string | null };

export function describeError(error: unknown): ErrorReport {
  if (error instanceof Error) return { message: error.message || error.name || 'Error', stack: error.stack ?? null };
  if (typeof error === 'string') return { message: error, stack: null };
  if (typeof error === 'object' && error !== null && 'message' in error) {
    return { message: String((error as { message: unknown }).message), stack: null };
  }
  return { message: 'Unknown error', stack: null };
}

// A dropped connection is not a bug in the app, and on mobile data it happens all the time. Reporting it would bury
// the real crashes, so these are left out.
const CONNECTION_NOISE = /network request failed|failed to fetch|fetch failed|load failed|networkerror|timed out|timeout|aborted|offline/i;

export function isConnectionNoise(message: string): boolean {
  return CONNECTION_NOISE.test(message);
}

// Remembers what was already sent in this session, so a screen that crashes in a loop sends one report, not hundreds.
export function createDeduper(limit = 20): (report: ErrorReport) => boolean {
  const seen = new Set<string>();
  return (report) => {
    if (isConnectionNoise(report.message) || !report.message.trim()) return false;
    const key = `${report.message}|${(report.stack ?? '').slice(0, 200)}`;
    if (seen.has(key) || seen.size >= limit) return false;
    seen.add(key);
    return true;
  };
}
