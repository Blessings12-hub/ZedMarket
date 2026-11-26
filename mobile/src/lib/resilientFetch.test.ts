import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createResilientFetch, isSafeToRepeat, isTransientError, withRetry } from './resilientFetch';

const ok = () => new Response('{}', { status: 200 });

test('reads and read-only functions are safe to repeat, writes are not', () => {
  assert.equal(isSafeToRepeat('GET', 'https://x.supabase.co/rest/v1/listings'), true);
  assert.equal(isSafeToRepeat('POST', 'https://x.supabase.co/auth/v1/token?grant_type=password'), true);
  assert.equal(isSafeToRepeat('POST', 'https://x.supabase.co/rest/v1/rpc/search_listings'), true);
  assert.equal(isSafeToRepeat('POST', 'https://x.supabase.co/rest/v1/rpc/place_order'), false);
  assert.equal(isSafeToRepeat('POST', 'https://x.supabase.co/rest/v1/orders'), false);
  assert.equal(isSafeToRepeat('DELETE', 'https://x.supabase.co/rest/v1/favourites'), false);
});

test('a read is retried after a network failure and then succeeds', async () => {
  let calls = 0;
  const f = createResilientFetch({ baseDelayMs: 1, retries: 3 }, (async () => {
    calls += 1;
    if (calls < 3) throw new TypeError('Network request failed');
    return ok();
  }) as typeof fetch);
  const res = await f('https://x.supabase.co/rest/v1/listings');
  assert.equal(res.status, 200);
  assert.equal(calls, 3);
});

test('a gateway error on a read is retried', async () => {
  let calls = 0;
  const f = createResilientFetch({ baseDelayMs: 1 }, (async () => {
    calls += 1;
    return calls === 1 ? new Response('', { status: 503 }) : ok();
  }) as typeof fetch);
  assert.equal((await f('https://x.supabase.co/rest/v1/categories')).status, 200);
  assert.equal(calls, 2);
});

test('a write is never repeated automatically', async () => {
  let calls = 0;
  const f = createResilientFetch({ baseDelayMs: 1 }, (async () => {
    calls += 1;
    throw new TypeError('Network request failed');
  }) as typeof fetch);
  await assert.rejects(() => f('https://x.supabase.co/rest/v1/orders', { method: 'POST', body: '{}' }));
  assert.equal(calls, 1);
});

test('a stalled request times out instead of hanging', async () => {
  const f = createResilientFetch({ timeoutMs: 20, retries: 0 }, ((_i: unknown, init?: RequestInit) =>
    new Promise((_res, rej) => init?.signal?.addEventListener('abort', () => rej(new Error('aborted'))))) as typeof fetch);
  await assert.rejects(() => f('https://x.supabase.co/rest/v1/listings'), /timed out/);
});

test('withRetry repeats transient errors only', async () => {
  let n = 0;
  const v = await withRetry(async () => { n += 1; if (n < 2) throw new Error('Failed to fetch'); return 'ok'; }, { baseDelayMs: 1 });
  assert.equal(v, 'ok');
  let m = 0;
  await assert.rejects(() => withRetry(async () => { m += 1; throw new Error('permission denied'); }, { baseDelayMs: 1 }));
  assert.equal(m, 1);
  assert.equal(isTransientError(new Error('Bad Gateway')), true);
});
