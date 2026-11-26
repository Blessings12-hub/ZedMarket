// A fetch that copes with weak or unstable mobile connections (MTN, Airtel, Zamtel and others).
//
// What it does:
//  - Gives every request a time limit, so a stalled connection fails instead of hanging forever.
//  - Retries short network failures and gateway errors (502, 503, 504, 408, 429) with a growing pause.
//  - Only retries requests that are safe to repeat: reads, sign-in token calls, and read-only database functions.
//    Requests that change data (creating an order, sending a message) are NOT repeated automatically, because
//    the first attempt may have worked and a repeat could create it twice. Those show a clear error instead.

export type ResilientOptions = {
  timeoutMs?: number;
  retries?: number;
  baseDelayMs?: number;
};

const DEFAULTS: Required<ResilientOptions> = {
  timeoutMs: 20000,
  retries: 3,
  baseDelayMs: 600,
};

// Database functions that only read. Anything not listed here is treated as a write and is not repeated.
const READ_RPC = /\/rest\/v1\/rpc\/(search_|featured_|trending_|nearby_|recommended_|recently_|payments_enabled|unread_|seller_agreement_current|seller_application_mine|my_|support_categories)/;

export function isSafeToRepeat(method: string, url: string): boolean {
  const m = method.toUpperCase();
  if (m === 'GET' || m === 'HEAD' || m === 'OPTIONS') return true;
  if (m === 'POST' && /\/auth\/v1\/token/.test(url)) return true; // sign-in and session refresh
  if (m === 'POST' && READ_RPC.test(url)) return true;
  return false;
}

const RETRY_STATUS = new Set([408, 425, 429, 502, 503, 504]);

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function backoffDelay(attempt: number, baseMs: number): number {
  const jitter = Math.random() * baseMs * 0.4;
  return baseMs * 2 ** attempt + jitter;
}

function requestInfo(input: RequestInfo | URL, init?: RequestInit): { url: string; method: string } {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
  const method = init?.method ?? (typeof input === 'object' && 'method' in input ? input.method : 'GET') ?? 'GET';
  return { url, method };
}

export function createResilientFetch(options: ResilientOptions = {}, baseFetch: typeof fetch = (...a) => fetch(...a)): typeof fetch {
  const cfg = { ...DEFAULTS, ...options };

  return async (input, init) => {
    const { url, method } = requestInfo(input, init);
    const repeatable = isSafeToRepeat(method, url);
    const attempts = repeatable ? cfg.retries + 1 : 1;
    let lastError: unknown;

    for (let attempt = 0; attempt < attempts; attempt += 1) {
      const controller = new AbortController();
      const callerSignal = init?.signal;
      const onCallerAbort = () => controller.abort();
      if (callerSignal) {
        if (callerSignal.aborted) throw new DOMException('Aborted', 'AbortError');
        callerSignal.addEventListener('abort', onCallerAbort);
      }
      // Uploads need longer than reads.
      const limit = /\/storage\/v1\/object\//.test(url) && method.toUpperCase() !== 'GET' ? cfg.timeoutMs * 3 : cfg.timeoutMs;
      const timer = setTimeout(() => controller.abort(), limit);

      try {
        const res = await baseFetch(input, { ...init, signal: controller.signal });
        if (repeatable && RETRY_STATUS.has(res.status) && attempt < attempts - 1) {
          lastError = new Error(`HTTP ${res.status}`);
        } else {
          return res;
        }
      } catch (error) {
        // The person cancelled it themselves: do not retry.
        if (callerSignal?.aborted) throw error;
        lastError = controller.signal.aborted ? new Error('The request timed out') : error;
        if (attempt >= attempts - 1) break;
      } finally {
        clearTimeout(timer);
        callerSignal?.removeEventListener('abort', onCallerAbort);
      }

      await sleep(backoffDelay(attempt, cfg.baseDelayMs));
    }

    throw lastError instanceof Error ? lastError : new Error('Network request failed');
  };
}

// For one-off actions that are safe to repeat when the connection drops (for example, putting a photo in storage).
export async function withRetry<T>(
  fn: () => Promise<T>,
  opts: { retries?: number; baseDelayMs?: number; shouldRetry?: (error: unknown) => boolean } = {},
): Promise<T> {
  const retries = opts.retries ?? 3;
  const base = opts.baseDelayMs ?? 800;
  const shouldRetry = opts.shouldRetry ?? isTransientError;
  let last: unknown;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      return await fn();
    } catch (error) {
      last = error;
      if (attempt === retries || !shouldRetry(error)) throw error;
      await sleep(backoffDelay(attempt, base));
    }
  }
  throw last;
}

export function isTransientError(error: unknown): boolean {
  const message =
    error instanceof Error ? error.message : typeof error === 'object' && error !== null && 'message' in error ? String((error as { message: unknown }).message) : '';
  return /network request failed|failed to fetch|fetch failed|timed out|timeout|load failed|networkerror|HTTP (408|425|429|502|503|504)|bad gateway|gateway time-?out|service unavailable/i.test(message);
}
