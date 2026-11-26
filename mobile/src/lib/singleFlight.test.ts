import assert from 'node:assert/strict';
import test from 'node:test';

import { exclusive, singleFlight } from './singleFlight';

test('repeated requests while one is running share it', async () => {
  let calls = 0;
  const load = singleFlight(async () => { calls += 1; await new Promise((r) => setTimeout(r, 10)); return calls; });
  const [a, b, c] = await Promise.all([load(), load(), load()]);
  assert.deepEqual([a, b, c, calls], [1, 1, 1, 1]);
  assert.equal(await load(), 2, 'a new request after it finished runs again');
});

test('a failed request does not leave the next one stuck', async () => {
  let n = 0;
  const load = singleFlight(async () => { n += 1; if (n === 1) throw new Error('first fails'); return n; });
  await assert.rejects(load(), /first fails/);
  assert.equal(await load(), 2);
});

test('a second press on an action is ignored while the first runs', async () => {
  let runs = 0;
  const close = exclusive(async () => { runs += 1; await new Promise((r) => setTimeout(r, 10)); return 'done'; });
  const [a, b] = await Promise.all([close(), close()]);
  assert.deepEqual([a, b, runs], ['done', undefined, 1]);
  assert.equal(await close(), 'done');
  assert.equal(runs, 2);
});
