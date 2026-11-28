import assert from 'node:assert/strict';
import test from 'node:test';

import { replySpeedLabel, toReplySpeed } from './replySpeed';

test('only the two known answers become a badge', () => {
  assert.equal(toReplySpeed('within_an_hour'), 'within_an_hour');
  assert.equal(toReplySpeed('within_a_day'), 'within_a_day');
  assert.equal(toReplySpeed(null), null);
  assert.equal(toReplySpeed('instant'), null);
});

test('the badge wording is plain and says nothing when there is no badge', () => {
  assert.equal(replySpeedLabel('within_an_hour'), 'Usually replies within an hour');
  assert.equal(replySpeedLabel('within_a_day'), 'Usually replies within a day');
  assert.equal(replySpeedLabel(null), null);
});
