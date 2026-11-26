import assert from 'node:assert/strict';
import test from 'node:test';

import { deliverTo, type DeliverToInput } from './deliverTo';

const base: DeliverToInput = { role: 'seller', fulfilment: 'delivery', status: 'requested', cancelKind: null, handedOverAt: null, buyerName: 'Bwalya', deliveryAddress: 'Plot 5, near the mall, Kabulonga, Lusaka', deliveryFee: 0, buyerNote: null };

test('a seller sees the address before confirming', () => {
  const d = deliverTo(base);
  assert.equal(d?.address, 'Plot 5, near the mall, Kabulonga, Lusaka');
  assert.equal(d?.buyerName, 'Bwalya');
  assert.match(d?.title ?? '', /before you confirm/i);
  assert.equal(d?.missing, false);
});

test('it stays while the order is confirmed and handed over', () => {
  assert.equal(deliverTo({ ...base, status: 'confirmed' })?.title, 'Deliver to');
  assert.ok(deliverTo({ ...base, status: 'confirmed', handedOverAt: '2026-11-20T10:00:00Z' }));
});

test('buyers and collection orders do not get the card', () => {
  assert.equal(deliverTo({ ...base, role: 'buyer' }), null);
  assert.equal(deliverTo({ ...base, fulfilment: 'collection' }), null);
});

test('finished, cancelled, declined and expired orders do not get it', () => {
  assert.equal(deliverTo({ ...base, status: 'completed' }), null);
  assert.equal(deliverTo({ ...base, status: 'cancelled', cancelKind: 'cancelled' }), null);
  assert.equal(deliverTo({ ...base, status: 'cancelled', cancelKind: 'declined' }), null);
  assert.equal(deliverTo({ ...base, status: 'cancelled', cancelKind: 'expired' }), null);
});

test('a missing address says so plainly and is flagged', () => {
  for (const a of [null, '', '   ']) {
    const d = deliverTo({ ...base, deliveryAddress: a });
    assert.equal(d?.missing, true);
    assert.match(d?.address ?? '', /did not give an address/i);
  }
});

test('the buyer note comes along only when there is one', () => {
  assert.equal(deliverTo({ ...base, buyerNote: '  Call at the gate ' })?.note, 'Call at the gate');
  assert.equal(deliverTo({ ...base, buyerNote: '  ' })?.note, null);
});
