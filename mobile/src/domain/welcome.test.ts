import assert from 'node:assert/strict';
import test from 'node:test';

import { shouldShowWelcome, WELCOME_SLIDES } from './welcome';

test('there are three plain slides', () => {
  assert.equal(WELCOME_SLIDES.length, 3);
  for (const s of WELCOME_SLIDES) assert.ok(s.title && s.body);
});

test('the welcome shows only when the phone has said it was not seen', () => {
  assert.equal(shouldShowWelcome(false, true), true);
  assert.equal(shouldShowWelcome(true, true), false);
  assert.equal(shouldShowWelcome(null, true), false);
  assert.equal(shouldShowWelcome(false, false), false);
});
