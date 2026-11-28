import assert from 'node:assert/strict';
import test from 'node:test';

import { SAFETY_SECTIONS } from './safetyTips';

test('the safety advice covers paying, chatting and what to do when something goes wrong', () => {
  const titles = SAFETY_SECTIONS.map((s) => s.title);
  assert.deepEqual(titles, ['Before you pay', 'Paying with mobile money', 'Chat and records', 'If something goes wrong']);
  for (const s of SAFETY_SECTIONS) assert.ok(s.points.length >= 3, s.title);
});

test('it warns people never to share a PIN or code', () => {
  const text = SAFETY_SECTIONS.flatMap((s) => s.points).join(' ');
  assert.match(text, /PIN/);
  assert.match(text, /before you press send/i);
});
