import assert from 'node:assert/strict';
import test from 'node:test';

import type { AdminRole } from '../../domain/admin';
import { staffBoard, waitingLabel, QUEUE_KEYS } from './dashboard';

const NOW = Date.parse('2026-11-26T12:00:00Z');
const ago = (hours: number) => new Date(NOW - hours * 3_600_000).toISOString();
const keys = (roles: AdminRole[], counts: Parameters<typeof staffBoard>[1]) => staffBoard(roles, counts, NOW).cards.map((c) => c.key);

test('waiting labels', () => {
  assert.equal(waitingLabel(ago(0.2), NOW), 'just arrived');
  assert.equal(waitingLabel(ago(1), NOW), 'waiting 1 hour');
  assert.equal(waitingLabel(ago(5), NOW), 'waiting 5 hours');
  assert.equal(waitingLabel(ago(72), NOW), 'waiting 3 days');
  assert.equal(waitingLabel(null, NOW), null);
  assert.equal(waitingLabel('not a date', NOW), null);
  assert.equal(waitingLabel(ago(-5), NOW), null);
});

test('empty queues are hidden and everything quiet says all clear', () => {
  const b = staffBoard(['support', 'moderator'], { disputes: { count: 0, oldest: null } }, NOW);
  assert.equal(b.allClear, true);
  assert.deepEqual(b.cards, []);
  assert.equal(b.total, 0);
  assert.equal(staffBoard(['support'], {}, NOW).allClear, true);
});

test('each role only sees the queues it may work', () => {
  const all = Object.fromEntries(QUEUE_KEYS.map((k) => [k, { count: 1, oldest: ago(2) }]));
  assert.deepEqual(keys(['finance'], all), []);
  assert.deepEqual(keys(['tech_admin'], all), []);
  assert.ok(keys(['moderator'], all).includes('listings'));
  assert.ok(!keys(['moderator'], all).includes('disputes'));
  assert.ok(!keys(['moderator'], all).includes('applications'));
  assert.ok(keys(['support'], all).includes('applications'));
  assert.ok(keys(['support'], all).includes('disputes'));
  assert.ok(!keys(['support'], all).includes('listings'));
});

test('urgent cards come first, then the one waiting longest', () => {
  const counts = {
    listings: { count: 9, oldest: ago(2) },
    reports: { count: 1, oldest: ago(30) },
    appeals: { count: 1, oldest: ago(100) },
  };
  assert.deepEqual(keys(['moderator', 'support'], counts), ['appeals', 'reports', 'listings']);
  const b = staffBoard(['moderator'], counts, NOW);
  assert.equal(b.cards[0]?.urgent, true);
  assert.equal(b.cards[1]?.urgent, false);
  assert.equal(b.total, 11);
});

test('overdue applications are urgent even when the oldest is recent', () => {
  const b = staffBoard(['support'], { applications: { count: 2, oldest: ago(3), overdue: 1 } }, NOW);
  assert.equal(b.cards[0]?.urgent, true);
});

test('bad counts and dates never break the board', () => {
  const b = staffBoard(['moderator'], { listings: { count: Number.NaN, oldest: 'x' }, reports: { count: -3, oldest: null }, flags: { count: 2.7, oldest: 'bad' } }, NOW);
  assert.deepEqual(b.cards.map((c) => [c.key, c.count, c.waiting]), [['flags', 2, null]]);
});

test('roles with no queue get no board rather than a false all clear', () => {
  assert.equal(staffBoard(['finance'], {}, NOW).hasQueues, false);
  assert.equal(staffBoard(['tech_admin'], {}, NOW).hasQueues, false);
  assert.equal(staffBoard(['moderator'], {}, NOW).hasQueues, true);
});
