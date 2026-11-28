import assert from 'node:assert/strict';
import { test } from 'node:test';

import { decisionError, priceFor, promotionStatusText, toMyPromotions, toPrices, toQueue } from './promotion';

test('price for each period', () => {
  const p = { d7: 50, d14: 100, d30: 200 };
  assert.equal(priceFor(p, 7), 50);
  assert.equal(priceFor(p, 14), 100);
  assert.equal(priceFor(p, 30), 200);
});

test('approving needs a payment reference, rejecting needs a reason', () => {
  assert.notEqual(decisionError(true, ' '), null);
  assert.notEqual(decisionError(true, 'ab'), null);
  assert.equal(decisionError(true, 'MoMo 1234'), null);
  assert.notEqual(decisionError(false, ''), null);
  assert.equal(decisionError(false, 'Photo is blurry'), null);
});

test('prices and rows from the server are read safely', () => {
  assert.deepEqual(toPrices({ d7: '50', d14: 100, d30: 200 }), { d7: 50, d14: 100, d30: 200 });
  assert.equal(toPrices({ d7: 'x' }), null);
  assert.equal(toPrices(null), null);
  assert.deepEqual(toMyPromotions(null), []);
  assert.equal(toMyPromotions([{ id: 'a', listing_id: 'b', title: 'T', days: 7, price_zmw: '50.00', status: 'requested', created_at: 'now' }])[0]?.price, 50);
  assert.equal(toQueue([{ id: 'a', listing_id: 'b', title: 'T', days: 7, price_zmw: 50, seller_name: 'Sam', created_at: 'now' }])[0]?.sellerName, 'Sam');
});

test('status text', () => {
  assert.match(promotionStatusText('requested'), /Waiting/);
  assert.equal(promotionStatusText('mystery'), 'mystery');
});
