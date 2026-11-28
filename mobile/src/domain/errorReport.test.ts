import assert from 'node:assert/strict';
import test from 'node:test';

import { createDeduper, describeError, isConnectionNoise } from './errorReport';

test('errors of any shape become a message and an optional stack', () => {
  assert.equal(describeError(new Error('boom')).message, 'boom');
  assert.ok(describeError(new Error('boom')).stack);
  assert.deepEqual(describeError('plain text'), { message: 'plain text', stack: null });
  assert.deepEqual(describeError({ message: 'from supabase' }), { message: 'from supabase', stack: null });
  assert.equal(describeError(undefined).message, 'Unknown error');
});

test('dropped connections are not reported as bugs', () => {
  assert.equal(isConnectionNoise('Network request failed'), true);
  assert.equal(isConnectionNoise('TypeError: Failed to fetch'), true);
  assert.equal(isConnectionNoise('Cannot read property x of undefined'), false);
});

test('the same crash is sent once per session, and the total is capped', () => {
  const send = createDeduper(2);
  assert.equal(send({ message: 'A', stack: 's' }), true);
  assert.equal(send({ message: 'A', stack: 's' }), false);
  assert.equal(send({ message: 'B', stack: null }), true);
  assert.equal(send({ message: 'C', stack: null }), false);
  assert.equal(send({ message: '  ', stack: null }), false);
  assert.equal(createDeduper()({ message: 'Network request failed', stack: null }), false);
});
