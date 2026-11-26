import assert from 'node:assert/strict';
import test from 'node:test';

import type { Place } from '../../domain/locations';
import { areaChoices, browseLabel, DEFAULT_PROVINCE, deliveryLong, deliveryShort, isMissingFunction, pickDeliveryAddress, provinceFor, validArea, type DeliveryAddress } from './area';

const places: Place[] = [
  { id: 1, province: 'Lusaka', district: 'Lusaka', town: 'Lusaka', area: null },
  { id: 2, province: 'Lusaka', district: 'Lusaka', town: 'Lusaka', area: 'Kabulonga' },
  { id: 3, province: 'Lusaka', district: 'Lusaka', town: 'Lusaka', area: 'Woodlands' },
  { id: 4, province: 'Lusaka', district: 'Kafue', town: 'Kafue', area: 'Kafue Estates' },
  { id: 5, province: 'Southern', district: 'Choma', town: 'Choma', area: 'Test Area' },
];

test('the browse province follows the delivery location and defaults to Lusaka', () => {
  assert.equal(DEFAULT_PROVINCE, 'Lusaka');
  assert.equal(provinceFor(places, null), 'Lusaka');
  assert.equal(provinceFor(places, undefined), 'Lusaka');
  assert.equal(provinceFor(places, 999), 'Lusaka');
  assert.equal(provinceFor(places, 5), 'Southern');
});

test('area choices are only named areas of the province, in order', () => {
  assert.deepEqual(areaChoices(places, 'Lusaka').map((a) => a.label), ['Kafue Estates, Kafue', 'Kabulonga, Lusaka', 'Woodlands, Lusaka']);
  assert.deepEqual(areaChoices(places, 'Southern').map((a) => a.id), [5]);
  assert.deepEqual(areaChoices(places, 'Copperbelt'), []);
});

test('typing narrows the choices, ignoring case and spaces at the ends', () => {
  assert.deepEqual(areaChoices(places, 'Lusaka', '  kabu ').map((a) => a.id), [2]);
  assert.deepEqual(areaChoices(places, 'Lusaka', 'kafue').map((a) => a.id), [4]);
  assert.deepEqual(areaChoices(places, 'Lusaka', 'zzz'), []);
});

test('the near-you label names the area, or says all of the province', () => {
  assert.equal(browseLabel(places, 'Lusaka', null), 'All of Lusaka');
  assert.equal(browseLabel(places, 'Lusaka', 2), 'Kabulonga, Lusaka');
  assert.equal(browseLabel(places, 'Lusaka', 5), 'All of Lusaka'); // an area from another province is ignored
});

test('an area from another province is dropped', () => {
  assert.equal(validArea(places, 'Lusaka', 2), 2);
  assert.equal(validArea(places, 'Lusaka', 5), null);
  assert.equal(validArea(places, 'Lusaka', null), null);
});

test('a missing server function is recognised, other errors are not', () => {
  assert.equal(isMissingFunction({ code: 'PGRST202', message: 'x' }), true);
  assert.equal(isMissingFunction({ code: '42883' }), true);
  assert.equal(isMissingFunction({ message: 'Could not find the function public.search_listings_in_province' }), true);
  assert.equal(isMissingFunction({ code: '57014', message: 'timeout' }), false);
  assert.equal(isMissingFunction(null), false);
});

const addr = (over: Partial<DeliveryAddress>): DeliveryAddress => ({ id: 'a', label: 'Home', kind: 'delivery', locationId: 2, street: null, landmark: null, isDefault: false, ...over });

test('the delivery address is the default one, never a pickup-only one', () => {
  assert.equal(pickDeliveryAddress([]), null);
  assert.equal(pickDeliveryAddress([addr({ id: 'p', kind: 'pickup', isDefault: true })]), null);
  assert.equal(pickDeliveryAddress([addr({ id: 'x' }), addr({ id: 'd', isDefault: true })])?.id, 'd');
  assert.equal(pickDeliveryAddress([addr({ id: 'p', kind: 'pickup' }), addr({ id: 'x', kind: 'both' })])?.id, 'x');
});

test('delivery lines for the top bar and for the order', () => {
  assert.equal(deliveryShort(places, addr({})), 'Kabulonga, Lusaka');
  assert.equal(deliveryShort(places, null), null);
  assert.equal(deliveryShort(places, addr({ locationId: 999 })), null);
  assert.equal(deliveryLong(places, addr({ street: ' Plot 5 ', landmark: 'near the mall' })), 'Plot 5, near the mall, Kabulonga, Lusaka');
  assert.equal(deliveryLong(places, addr({})), 'Kabulonga, Lusaka');
  assert.equal(deliveryLong(places, null), null);
});
