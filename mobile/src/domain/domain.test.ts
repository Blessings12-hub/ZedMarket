import assert from 'node:assert/strict';
import { test } from 'node:test';

import { canMove, etaLabel, isFinished, isInProgress } from './delivery';
import { validateListing, type ListingForm } from './listing';
import { formatKwacha, parsePrice } from './money';
import { cleanSearchTerm, describeSearch, searchFilter } from './search';

test('formatKwacha', () => {
  assert.equal(formatKwacha(2350), 'K2,350');
  assert.equal(formatKwacha(1250.5), 'K1,250.50');
});

test('parsePrice accepts common ways of typing a price', () => {
  assert.equal(parsePrice('2500'), 2500);
  assert.equal(parsePrice('2,500'), 2500);
  assert.equal(parsePrice('K 2500.50'), 2500.5);
  assert.equal(parsePrice('ZMW 90'), 90);
});

test('parsePrice rejects bad input', () => {
  for (const bad of ['', 'abc', '0', '-5', '12.345', '1e6', '100000000']) {
    assert.equal(parsePrice(bad), null, `"${bad}" should not parse`);
  }
});

test('cleanSearchTerm removes characters that change a filter', () => {
  assert.equal(cleanSearchTerm('  tv,(43)  "smart"  '), 'tv 43 smart');
  assert.equal(cleanSearchTerm('100%_off'), '100 off');
  assert.equal(searchFilter('a'), null);
  assert.equal(searchFilter('sofa'), 'title.ilike.%sofa%,description.ilike.%sofa%');
});

const goodForm: ListingForm = {
  title: 'Samsung Galaxy A14',
  price: '2350',
  description: '',
  categoryId: 1,
  locationId: 3,
  condition: 'used_good',
  warrantyInfo: '',
  returnPolicy: '',
  photoCount: 2,
};

test('validateListing passes a complete form', () => {
  assert.deepEqual(validateListing(goodForm), {});
});

test('validateListing reports each problem', () => {
  const errors = validateListing({
    ...goodForm,
    title: 'ab',
    price: 'free',
    categoryId: null,
    locationId: null,
    condition: null,
    photoCount: 0,
  });
  assert.deepEqual(Object.keys(errors).sort(), ['categoryId', 'condition', 'locationId', 'photoCount', 'price', 'title']);
});

test('delivery statuses only move forward', () => {
  assert.equal(canMove('requested', 'assigned'), true);
  assert.equal(canMove('assigned', 'picked_up'), true); // at_pickup is optional
  assert.equal(canMove('in_transit', 'assigned'), false);
  assert.equal(canMove('delivered', 'in_transit'), false);
  assert.equal(canMove('cancelled', 'requested'), false);
});

test('finished and in-progress statuses', () => {
  assert.equal(isFinished('delivered'), true);
  assert.equal(isFinished('failed'), true);
  assert.equal(isFinished('in_transit'), false);
  assert.equal(isInProgress('requested'), false);
  assert.equal(isInProgress('in_transit'), true);
});

test('an arrival time needs a source and is never shown once finished', () => {
  const iso = '2026-12-01T10:30:00Z';
  assert.equal(etaLabel({ status: 'in_transit', estimated_arrival: null, estimated_arrival_source: null }), null);
  assert.equal(etaLabel({ status: 'in_transit', estimated_arrival: iso, estimated_arrival_source: null }), null);
  assert.equal(etaLabel({ status: 'delivered', estimated_arrival: iso, estimated_arrival_source: 'provider' }), null);
  const label = etaLabel({ status: 'in_transit', estimated_arrival: iso, estimated_arrival_source: 'provider' });
  assert.ok(label?.startsWith('Estimated arrival around'));
});

test('saved search names read like what the person chose', () => {
  assert.equal(
    describeSearch({ term: ' phone ', categoryName: 'Electronics', areaName: 'Kabulonga', maxPrice: 600 }),
    'phone · Electronics · Kabulonga · up to K600',
  );
  assert.equal(describeSearch({ term: '', minPrice: 100, maxPrice: 300 }), 'K100 to K300');
  assert.equal(describeSearch({ term: '', minPrice: 100 }), 'from K100');
  assert.equal(describeSearch({ term: '' }), 'My search');
  assert.equal(describeSearch({ term: 'x'.repeat(200) }).length <= 60, true);
});
