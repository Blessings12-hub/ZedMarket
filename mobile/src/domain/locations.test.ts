import assert from 'node:assert/strict';
import test from 'node:test';

import { areasIn, coordinatesProblem, coverageMessage, deliverySummary, districtsIn, formatPlace, mapsLink, provinces, townsIn, validateAddress, type Place } from './locations';

const places: Place[] = [
  { id: 1, province: 'Lusaka', district: 'Lusaka', town: 'Lusaka', area: null },
  { id: 2, province: 'Lusaka', district: 'Lusaka', town: 'Lusaka', area: 'Kabulonga' },
  { id: 3, province: 'Lusaka', district: 'Lusaka', town: 'Lusaka', area: 'Chilenje' },
  { id: 4, province: 'Copperbelt', district: 'Ndola', town: 'Ndola', area: null },
  { id: 5, province: 'Copperbelt', district: null, town: 'Old', area: null },
];

test('the place tree is built from the flat list', () => {
  assert.deepEqual(provinces(places), ['Copperbelt', 'Lusaka']);
  assert.deepEqual(districtsIn(places, 'Copperbelt'), ['Ndola']);
  assert.deepEqual(townsIn(places, 'Lusaka', 'Lusaka'), ['Lusaka']);
  assert.deepEqual(areasIn(places, 'Lusaka', 'Lusaka', 'Lusaka').map((p) => p.id), [1, 3, 2]);
});

test('formatPlace', () => {
  assert.equal(formatPlace({ town: 'Lusaka', area: 'Kabulonga' }), 'Kabulonga, Lusaka');
  assert.equal(formatPlace({ town: 'Ndola', area: null }), 'Ndola');
});

test('coordinates must be a pair inside Zambia', () => {
  assert.equal(coordinatesProblem(null, null), null);
  assert.equal(coordinatesProblem(-15.4, 28.3), null);
  assert.ok(coordinatesProblem(-15.4, null));
  assert.ok(coordinatesProblem(51.5, -0.1));
  assert.ok(coordinatesProblem(Number.NaN, 28));
});

test('address validation', () => {
  const ok = { label: 'Home', kind: 'both' as const, locationId: 2, street: 'Plot 5', landmark: '', directions: '' };
  assert.equal(validateAddress(ok), null);
  assert.ok(validateAddress({ ...ok, label: ' ' }));
  assert.ok(validateAddress({ ...ok, locationId: null }));
  assert.ok(validateAddress({ ...ok, street: '', landmark: '' }));
  assert.equal(validateAddress({ ...ok, street: '', landmark: 'Blue gate' }), null);
  assert.ok(validateAddress({ ...ok, directions: 'x'.repeat(301) }));
});

test('coverage messages block only when delivery is not possible', () => {
  assert.equal(coverageMessage('covered').ok, true);
  assert.equal(coverageMessage('unrestricted').ok, true);
  assert.equal(coverageMessage('outside').ok, false);
  assert.equal(coverageMessage('needs_area').ok, false);
});

test('delivery summary stays short and is empty when unrestricted', () => {
  assert.equal(deliverySummary(null), null);
  assert.equal(deliverySummary({ restricted: false, areas: [] }), null);
  assert.equal(deliverySummary({ restricted: true, areas: [{ level: 'town', label: 'Ndola' }] }), 'Delivers to: Ndola');
  const many = ['A', 'B', 'C', 'D', 'E'].map((label) => ({ level: 'town', label }));
  assert.equal(deliverySummary({ restricted: true, areas: many }), 'Delivers to: A; B; C and 2 more');
});

test('maps link only with real coordinates', () => {
  assert.equal(mapsLink(null, null), null);
  assert.equal(mapsLink(10, 10), null);
  assert.equal(mapsLink(-15.4, 28.3), 'https://www.google.com/maps/search/?api=1&query=-15.4,28.3');
});
