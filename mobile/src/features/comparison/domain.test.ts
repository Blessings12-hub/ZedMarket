import assert from 'node:assert/strict';
import { test } from 'node:test';
import { canCompare, cheapestId, normalizeComparison, toggleCompare } from './domain';

test('toggling adds, removes and stops at four with a visible "full"', () => {
  let ids: string[] = [];
  for (const id of ['a', 'b', 'c', 'd']) ids = toggleCompare(ids, id).ids;
  assert.equal(ids.length, 4);
  assert.deepEqual(toggleCompare(ids, 'e'), { ids, full: true });
  assert.deepEqual(toggleCompare(ids, 'a').ids, ['b', 'c', 'd']);
});
test('two to four can be compared', () => {
  assert.equal(canCompare(['a']), false);
  assert.equal(canCompare(['a', 'b']), true);
  assert.equal(canCompare(['a', 'b', 'c', 'd', 'e']), false);
});
test('a thin answer still normalises and an empty one is an error', () => {
  const c = normalizeComparison({ items: [{ id: 'x', price: '10' }] });
  assert.equal(c.items[0]?.price, 10);
  assert.equal(c.items[0]?.warranty, null);
  assert.equal(c.sameCategory, true);
  assert.deepEqual(c.missing, []);
  assert.throws(() => normalizeComparison(null));
});
test('the cheapest listing is marked only when there is something to compare', () => {
  const base = { title: '', condition: '', warranty: null, returnPolicy: null, category: '', town: null, area: null, sellerName: '', sellerLevel: '', rating: null, reviews: 0, completedOrders: 0, image: null };
  assert.equal(cheapestId([{ ...base, id: 'a', price: 5 }]), null);
  assert.equal(cheapestId([{ ...base, id: 'a', price: 5 }, { ...base, id: 'b', price: 3 }]), 'b');
});
