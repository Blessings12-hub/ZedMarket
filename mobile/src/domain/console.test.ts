import assert from 'node:assert/strict';
import test from 'node:test';

import { CONSOLE_ITEMS, activeItemKey, consoleMenu, isWide } from './console';

const keys = (roles: Parameters<typeof consoleMenu>[0]) => consoleMenu(roles).flatMap((g) => g.items.map((i) => i.key));

test('a person with no staff role sees no menu', () => {
  assert.deepEqual(consoleMenu([]), []);
});

test('every staff member gets voting and birthdays', () => {
  for (const role of ['support', 'moderator', 'finance', 'tech_admin'] as const) {
    assert.ok(keys([role]).includes('votes') && keys([role]).includes('birthdays'), role);
  }
});

test('each role sees only its own sections', () => {
  assert.deepEqual(keys(['finance']), ['finance', 'stats', 'votes', 'birthdays']);
  assert.deepEqual(keys(['moderator']), ['listings', 'appeals', 'flags', 'reports', 'users', 'stats', 'votes', 'birthdays']);
  assert.ok(!keys(['moderator']).includes('finance') && !keys(['moderator']).includes('team'));
  assert.ok(keys(['support']).includes('verifications') && keys(['support']).includes('helpdesk'));
  assert.ok(!keys(['support']).includes('listings'));
  assert.ok(keys(['tech_admin']).includes('team') && keys(['tech_admin']).includes('audit') && keys(['tech_admin']).includes('helpdesk'));
  assert.ok(!keys(['tech_admin']).includes('finance'));
});

test('menu groups keep a fixed order and have no empty groups', () => {
  const groups = consoleMenu(['support', 'moderator', 'finance', 'tech_admin']).map((g) => g.group);
  assert.deepEqual(groups, ['Moderation', 'People', 'Money', 'Platform', 'Staff']);
  assert.deepEqual(consoleMenu(['finance']).map((g) => g.group), ['Money', 'Platform', 'Staff']);
});

test('every item is inside the console and unique', () => {
  assert.ok(CONSOLE_ITEMS.every((i) => i.href.startsWith('/console/')));
  assert.equal(new Set(CONSOLE_ITEMS.map((i) => i.key)).size, CONSOLE_ITEMS.length);
  assert.equal(new Set(CONSOLE_ITEMS.map((i) => i.href)).size, CONSOLE_ITEMS.length);
});

test('the active item follows the path, including sub-pages', () => {
  assert.equal(activeItemKey('/console/votes'), 'votes');
  assert.equal(activeItemKey('/console/votes/new'), 'votes');
  assert.equal(activeItemKey('/console/trust/user/abc'), 'users');
  assert.equal(activeItemKey('/console'), null);
  assert.equal(activeItemKey('/console/votesx'), null);
});

test('wide layout starts at 900 pixels', () => {
  assert.equal(isWide(899), false);
  assert.equal(isWide(900), true);
});
