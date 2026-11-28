import assert from 'node:assert/strict';
import { test } from 'node:test';

import { canEnterPin, cleanPin, isLive, nextStep, pinReady, pinResultMessage, toDeliveryView } from './ownDelivery';

test('the seller moves the delivery one step at a time', () => {
  assert.equal(nextStep('assigned')?.to, 'picked_up');
  assert.equal(nextStep('picked_up')?.to, 'in_transit');
  assert.equal(nextStep('in_transit'), null);
  assert.equal(nextStep('delivered'), null);
});

test('the PIN can only be entered once the item is with the rider and tries are left', () => {
  assert.equal(canEnterPin('assigned', 5), false);
  assert.equal(canEnterPin('picked_up', 5), true);
  assert.equal(canEnterPin('in_transit', 0), false);
  assert.equal(canEnterPin('delivered', 5), false);
});

test('PIN text is cleaned to four digits', () => {
  assert.equal(cleanPin('12 a3-4567'), '1234');
  assert.equal(pinReady('123'), false);
  assert.equal(pinReady('1234'), true);
});

test('messages for a right, wrong and locked PIN', () => {
  assert.match(pinResultMessage(true, 5), /accepted/);
  assert.match(pinResultMessage(false, 4), /4 tries left/);
  assert.match(pinResultMessage(false, 1), /1 try left/);
  assert.match(pinResultMessage(false, 0), /Too many/);
});

test('only active deliveries are live', () => {
  assert.equal(isLive('assigned'), true);
  assert.equal(isLive('cancelled'), false);
});

test('a bad server answer becomes null', () => {
  assert.equal(toDeliveryView(null), null);
  assert.equal(toDeliveryView({ id: 1 }), null);
  const v = toDeliveryView({ id: 'a', status: 'assigned', rider_name: null, pickup_address: 'p', destination_address: 'd', status_reason: null, pin: '1234', attempts_left: 5, events: [] });
  assert.equal(v?.pin, '1234');
});
