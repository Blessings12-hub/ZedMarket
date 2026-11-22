import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isPublicRoute } from './routes';

test('guests can browse, open listings and open seller pages', () => {
  assert.equal(isPublicRoute(['(tabs)']), true);
  assert.equal(isPublicRoute(['(tabs)', 'index']), true);
  assert.equal(isPublicRoute(['listing', '[id]']), true);
  assert.equal(isPublicRoute(['seller', '[id]']), true);
  assert.equal(isPublicRoute(['(auth)', 'sign-in']), true);
  assert.equal(isPublicRoute([]), true);
});

test('everything that needs an account stays private', () => {
  for (const segments of [
    ['(tabs)', 'sell'],
    ['(tabs)', 'messages'],
    ['(tabs)', 'account'],
    ['chat', '[id]'],
    ['orders'],
    ['order', '[id]'],
    ['checkout', '[listingId]'],
    ['saved'],
    ['alerts'],
    ['report'],
    ['verify', 'identity'],
    ['review', '[orderId]'],
    ['dispute', 'open'],
    ['appeal'],
    ['admin'],
    ['admin', 'listings'],
    ['trust'],
    ['trust', 'applications'],
    ['trust', 'user', 'abc'],
  ]) {
    assert.equal(isPublicRoute(segments), false, segments.join('/'));
  }
});
