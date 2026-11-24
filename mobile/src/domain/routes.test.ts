import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isPublicRoute } from './routes';

test('guests can browse, open listings and open seller pages', () => {
  assert.equal(isPublicRoute(['(tabs)']), true);
  assert.equal(isPublicRoute(['(tabs)', 'index']), true);
  assert.equal(isPublicRoute(['(tabs)', 'cart']), true);
  assert.equal(isPublicRoute(['listing', '[id]']), true);
  assert.equal(isPublicRoute(['seller', '[id]']), true);
  assert.equal(isPublicRoute(['business', '[slug]']), true);
  assert.equal(isPublicRoute(['(auth)', 'sign-in']), true);
  assert.equal(isPublicRoute([]), true);
});

test('everything that needs an account stays private', () => {
  for (const segments of [
    ['(tabs)', 'sell'],
    ['(tabs)', 'orders'],
    ['(tabs)', 'messages'],
    ['(tabs)', 'account'],
    ['chat', '[id]'],
    ['orders'],
    ['order', '[id]'],
    ['checkout', '[listingId]'],
    ['saved'],
    ['alerts'],
    ['notifications'],
    ['payments'],
    ['support'],
    ['support', 'new'],
    ['support', '[id]'],
    ['helpdesk'],
    ['helpdesk', 'performance'],
    ['helpdesk', 'ticket', '[id]'],
    ['pay', '[orderId]'],
    ['finance'],
    ['finance', 'payment', '[id]'],
    ['notification-settings'],
    ['report'],
    ['verify', 'identity'],
    ['review', '[orderId]'],
    ['dispute', 'open'],
    ['appeal'],
    ['admin'],
    ['admin', 'listings'],
    ['trust'],
    ['business', 'manage'],
    ['business', 'manage', '[id]'],
    ['business', 'manage', '[id]', 'inventory'],
    ['business', 'invitations'],
    ['trust', 'applications'],
    ['trust', 'user', 'abc'],
  ]) {
    assert.equal(isPublicRoute(segments), false, segments.join('/'));
  }
});
