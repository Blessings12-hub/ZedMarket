import assert from 'node:assert/strict';
import test from 'node:test';

import { STAFF_MENU_KEYS, staffMenu } from './staffMenu';

const keys = (roles: Parameters<typeof staffMenu>[0]) => staffMenu(roles).flatMap((s) => s.items.map((i) => i.key));

test('no role, no menu', () => assert.deepEqual(staffMenu([]), []));

test('each role sees only its own tools, plus the shared team tools', () => {
  assert.deepEqual(keys(['finance']), ['finance', 'stats', 'jobs', 'votes', 'birthdays']);
  assert.deepEqual(keys(['moderator']), ['listings', 'appeals', 'flags', 'reports', 'users', 'stats', 'jobs', 'votes', 'birthdays']);
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
