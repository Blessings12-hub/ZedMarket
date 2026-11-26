import assert from 'node:assert/strict';
import test from 'node:test';

import { BUSINESS_CLOSE, SELLER_CLOSE } from './closeAccount';

test('both warnings say it cannot be undone and that verification starts again', () => {
  for (const c of [SELLER_CLOSE, BUSINESS_CLOSE]) {
    assert.match(c.intro, /cannot be undone/i);
    assert.ok(c.points.some((p) => /from the start/i.test(p)), c.heading);
    assert.ok(c.points.some((p) => /open orders/i.test(p)), c.heading);
    assert.notEqual(c.confirm, c.button, 'the confirming button is worded differently from the one that opens the warning');
  }
});

test('the seller warning says a buyer account is kept and the business warning says who can delete', () => {
  assert.ok(SELLER_CLOSE.points.some((p) => /buyer account/i.test(p)));
  assert.ok(BUSINESS_CLOSE.points.some((p) => /only the owner/i.test(p)));
});
