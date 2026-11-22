import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  actionLabel,
  availableActions,
  canReview,
  eventText,
  expiryText,
  orderPhase,
  parseDeliveryFee,
  phaseLabel,
  receiptText,
  validateCheckout,
  type OrderAction,
  type OrderPhase,
  type OrderRole,
} from './orders';

// The same list the database test (supabase/tests/orders.sql) uses. If one changes, change both.
const ALLOWED_BY_DATABASE = [
  'requested|confirm|seller', 'requested|decline|seller', 'requested|cancel|buyer',
  'confirmed|cancel|buyer', 'confirmed|cancel|seller', 'confirmed|handover|seller',
  'confirmed|complete|buyer', 'confirmed|dispute|buyer', 'confirmed|dispute|seller',
  'handed_over|complete|buyer', 'handed_over|dispute|buyer', 'handed_over|dispute|seller',
  'completed|dispute|buyer', 'completed|dispute|seller',
];

test('the app offers exactly the steps the database allows', () => {
  const phases: OrderPhase[] = ['requested', 'confirmed', 'handed_over', 'completed', 'cancelled', 'declined', 'expired', 'disputed'];
  const actions: OrderAction[] = ['confirm', 'decline', 'cancel', 'handover', 'complete', 'dispute'];
  const roles: OrderRole[] = ['buyer', 'seller'];
  for (const phase of phases) {
    for (const action of actions) {
      for (const role of roles) {
        const offered = availableActions(role, phase).includes(action);
        // 'declined' and 'expired' are kinds of cancelled in the database, which allows nothing.
        const dbPhase = phase === 'declined' || phase === 'expired' ? 'cancelled' : phase;
        const allowed = ALLOWED_BY_DATABASE.includes(`${dbPhase}|${action}|${role}`);
        assert.equal(offered, allowed, `${role} ${action} when ${phase}`);
      }
    }
  }
});

test('phase comes from status, how it ended and whether it was handed over', () => {
  assert.equal(orderPhase({ status: 'requested', cancelKind: null, handedOverAt: null }), 'requested');
  assert.equal(orderPhase({ status: 'confirmed', cancelKind: null, handedOverAt: null }), 'confirmed');
  assert.equal(orderPhase({ status: 'confirmed', cancelKind: null, handedOverAt: '2026-11-01T10:00:00Z' }), 'handed_over');
  assert.equal(orderPhase({ status: 'cancelled', cancelKind: 'declined', handedOverAt: null }), 'declined');
  assert.equal(orderPhase({ status: 'cancelled', cancelKind: 'expired', handedOverAt: null }), 'expired');
  assert.equal(orderPhase({ status: 'cancelled', cancelKind: 'cancelled', handedOverAt: null }), 'cancelled');
  assert.equal(orderPhase({ status: 'disputed', cancelKind: null, handedOverAt: null }), 'disputed');
});

test('reviews only after completion and only once', () => {
  assert.equal(canReview('completed', false), true);
  assert.equal(canReview('completed', true), false);
  assert.equal(canReview('disputed', false), false);
  assert.equal(canReview('confirmed', false), false);
});

test('labels speak to the right person', () => {
  assert.equal(phaseLabel('requested', 'buyer', 'collection'), 'Waiting for the seller to answer');
  assert.equal(phaseLabel('requested', 'seller', 'collection'), 'Waiting for you to answer');
  assert.match(phaseLabel('confirmed', 'buyer', 'delivery'), /Delivery/);
  assert.equal(actionLabel('handover', 'delivery'), 'Mark as delivered');
  assert.equal(actionLabel('handover', 'collection'), 'Mark as collected');
});

test('expiry text counts down and never promises more than the deadline', () => {
  const now = new Date('2026-11-20T12:00:00Z');
  assert.equal(expiryText(null, now), null);
  assert.equal(expiryText('2026-11-20T11:00:00Z', now), 'The time to answer has passed. This order will close shortly.');
  assert.equal(expiryText('2026-11-20T12:30:00Z', now), 'Closes in 1 hour if nothing happens');
  assert.equal(expiryText('2026-11-20T18:00:00Z', now), 'Closes in 6 hours if nothing happens');
  assert.equal(expiryText('2026-11-22T11:00:00Z', now), 'Closes in 2 days if nothing happens');
  assert.equal(expiryText('not a date', now), null);
});

test('checkout needs an address for delivery and keeps text short', () => {
  assert.equal(validateCheckout({ fulfilment: 'collection', address: '', note: '' }), null);
  assert.match(validateCheckout({ fulfilment: 'delivery', address: '   ', note: '' }) ?? '', /delivery address/i);
  assert.equal(validateCheckout({ fulfilment: 'delivery', address: 'Near the blue gate', note: '' }), null);
  assert.match(validateCheckout({ fulfilment: 'collection', address: '', note: 'x'.repeat(301) }) ?? '', /300/);
});

test('delivery fee text is read carefully', () => {
  assert.deepEqual(parseDeliveryFee(''), { fee: 0 });
  assert.deepEqual(parseDeliveryFee('  '), { fee: 0 });
  assert.deepEqual(parseDeliveryFee('50'), { fee: 50 });
  assert.deepEqual(parseDeliveryFee('K 75.50'), { fee: 75.5 });
  assert.deepEqual(parseDeliveryFee('1,200'), { fee: 1200 });
  assert.ok('error' in parseDeliveryFee('abc'));
  assert.ok('error' in parseDeliveryFee('-5'));
  assert.ok('error' in parseDeliveryFee('10.999'));
  assert.ok('error' in parseDeliveryFee('100001'));
  assert.deepEqual(parseDeliveryFee('100000'), { fee: 100000 });
});

test('history lines say who did what', () => {
  assert.match(eventText('declined', 'system', 'collection'), /no longer available/);
  assert.equal(eventText('declined', 'seller', 'collection'), 'The seller declined the order');
  assert.equal(eventText('handed_over', 'seller', 'delivery'), 'The seller marked it as delivered');
  assert.equal(eventText('handed_over', 'seller', 'collection'), 'The seller marked it as collected');
  assert.equal(eventText('cancelled', 'buyer', 'collection'), 'The buyer cancelled');
  assert.match(eventText('auto_completed', 'system', 'collection'), /automatically/);
});

test('receipt text carries the agreed total and the no-payment statement', () => {
  const text = receiptText({
    receipt_number: 'ZM-001042',
    order_status: 'completed',
    item: 'Samsung phone',
    item_price_zmw: 500,
    delivery_fee_zmw: 75,
    total_zmw: 575,
    fulfilment: 'delivery',
    buyer: 'Buyer Test',
    seller: 'Seller Test',
    requested_at: '2026-11-01T08:00:00Z',
    confirmed_at: '2026-11-01T09:00:00Z',
    handed_over_at: null,
    completed_at: '2026-11-02T10:00:00Z',
    payment_note: 'ZedMarket did not take, hold or confirm any payment for this order.',
  });
  assert.match(text, /^ZedMarket receipt ZM-001042/);
  assert.match(text, /Total agreed: K ?575/);
  assert.match(text, /Delivery fee: K ?75/);
  assert.match(text, /did not take, hold or confirm any payment/);
  const noFee = receiptText({ ...JSON.parse(JSON.stringify({ receipt_number: 'ZM-1', order_status: 'completed', item: 'x', item_price_zmw: 10, delivery_fee_zmw: 0, total_zmw: 10, fulfilment: 'collection', buyer: 'a', seller: 'b', requested_at: '2026-11-01T08:00:00Z', confirmed_at: null, handed_over_at: null, completed_at: '2026-11-02T10:00:00Z', payment_note: 'n' })) });
  assert.equal(noFee.includes('Delivery fee'), false);
});
