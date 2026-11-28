import assert from 'node:assert/strict';
import test from 'node:test';

import { STAFF_MENU_KEYS, staffMenu } from './staffMenu';

const keys = (roles: Parameters<typeof staffMenu>[0]) => staffMenu(roles).flatMap((s) => s.items.map((i) => i.key));

test('no role, no menu', () => assert.deepEqual(staffMenu([]), []));

test('each role sees only its own tools, plus the shared team tools', () => {
  assert.deepEqual(keys(['finance']), ['finance', 'stats', 'media_ask', 'jobs', 'votes', 'birthdays']);
  assert.deepEqual(keys(['moderator']), ['listings', 'appeals', 'promotions', 'flags', 'reports', 'users', 'stats', 'media_ask', 'jobs', 'votes', 'birthdays']);
  assert.ok(keys(['support']).includes('helpdesk') && keys(['support']).includes('verifications'));
  assert.ok(!keys(['support']).includes('listings') && !keys(['support']).includes('finance'));
  assert.ok(keys(['tech_admin']).includes('team') && keys(['tech_admin']).includes('audit'));
  assert.ok(!keys(['tech_admin']).includes('finance') && !keys(['moderator']).includes('team'));
});

test('keys are unique, every row has a note, and empty sections are dropped', () => {
  assert.equal(new Set(STAFF_MENU_KEYS).size, STAFF_MENU_KEYS.length);
  for (const s of staffMenu(['finance', 'moderator', 'support', 'tech_admin'])) {
    assert.ok(s.items.length > 0);
    for (const i of s.items) assert.ok(i.note.length > 10 && i.href.startsWith('/'));
  }
  assert.ok(!staffMenu(['finance']).some((s) => s.title === 'Moderation'));
});

test('Media rows follow permissions, not just the role', () => {
  const media = ['media.access', 'media.requests'];
  assert.ok(keys(['media']).includes('jobs'));
  assert.ok(!keys(['media']).includes('media'));
  assert.deepEqual(staffMenu(['media'], media).flatMap((s) => s.items.map((i) => i.key)).filter((k) => k.startsWith('media')), ['media']);
  assert.ok(keys(['support']).includes('media_ask'));
  assert.ok(!keys(['support']).includes('media') && !keys(['support']).includes('media_people'));
  assert.ok(keys(['tech_admin']).includes('media_people'));
  const m = staffMenu(['media'], media).flatMap((s) => s.items.map((i) => i.key));
  for (const forbidden of ['finance', 'verifications', 'users', 'team', 'audit', 'listings']) assert.ok(!m.includes(forbidden));
});

test('the app health page is for technical administrators only', () => {
  assert.ok(keys(['tech_admin']).includes('health'));
  for (const r of ['support', 'moderator', 'finance'] as const) assert.ok(!keys([r]).includes('health'), r);
});
