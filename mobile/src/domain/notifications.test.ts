import assert from 'node:assert/strict';
import test from 'node:test';

import { canTurnOff, relativeTime, routeForNotification, unreadLabel } from './notifications';

test('links open only known screens', () => {
  assert.equal(routeForNotification('/order/abc-123'), '/order/abc-123');
  assert.equal(routeForNotification('/chat/9f'), '/chat/9f');
  assert.equal(routeForNotification('/account'), '/(tabs)/account');
  assert.equal(routeForNotification('/admin/audit'), null);
  assert.equal(routeForNotification('/order/../admin'), null);
  assert.equal(routeForNotification('//evil.example'), null);
  assert.equal(routeForNotification('https://evil.example'), null);
  assert.equal(routeForNotification(null), null);
  assert.equal(routeForNotification('/'), null);
});

test('a staff vote link opens that vote, but no other staff screen is reachable from a notification', () => {
  assert.equal(routeForNotification('/admin/votes/0b6c1f0e-1111-4222-8333-444455556666'), '/admin/votes/0b6c1f0e-1111-4222-8333-444455556666');
  assert.equal(routeForNotification('/admin/votes'), null);
  assert.equal(routeForNotification('/admin/votes/new'), null);
  assert.equal(routeForNotification('/admin/team'), null);
  assert.equal(routeForNotification('/admin/votes/../team'), null);
});

test('a birthday board link opens that board, and nothing else under /admin/birthdays', () => {
  assert.equal(routeForNotification('/admin/birthdays/0b6c1f0e-1111-4222-8333-444455556666'), '/admin/birthdays/0b6c1f0e-1111-4222-8333-444455556666');
  assert.equal(routeForNotification('/admin/birthdays'), null);
  assert.equal(routeForNotification('/admin/birthdays/reports'), null);
  assert.equal(routeForNotification('/admin/birthdays/mine'), null);
  assert.equal(routeForNotification('/admin/birthdays/../team'), null);
});

test('the staff category can be muted', () => {
  assert.equal(canTurnOff('staff'), true);
});

test('unread label caps at 99+', () => {
  assert.equal(unreadLabel(0), '');
  assert.equal(unreadLabel(7), '7');
  assert.equal(unreadLabel(250), '99+');
});

test('account notices cannot be turned off', () => {
  assert.equal(canTurnOff('account'), false);
  assert.equal(canTurnOff('orders'), true);
});

test('relative time', () => {
  const now = new Date('2026-11-22T12:00:00Z');
  assert.equal(relativeTime('2026-11-22T11:59:40Z', now), 'Just now');
  assert.equal(relativeTime('2026-11-22T11:30:00Z', now), '30 min ago');
  assert.equal(relativeTime('2026-11-22T09:00:00Z', now), '3 h ago');
  assert.equal(relativeTime('2026-11-20T12:00:00Z', now), '2 d ago');
  assert.equal(relativeTime('2026-10-01T12:00:00Z', now), '2026-10-01');
  assert.equal(relativeTime('nonsense', now), '');
});
