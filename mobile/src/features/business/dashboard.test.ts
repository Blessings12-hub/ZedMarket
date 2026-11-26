import assert from 'node:assert/strict';
import test from 'node:test';

import { attentionTiles, PRODUCTS_GOAL, salesSummary, setupChecklist } from './dashboard';

const f = { requested: 2, confirmed: 3, lowStock: 1, outOfStock: 2, disputed: 0 };
const s0 = { branches: 0, products: 0, catalogues: 0, verified: false };

test('tiles show only what has something in it, orders first', () => {
  const t = attentionTiles('owner', f);
  assert.deepEqual(t.map((x) => x.key), ['orders', 'in-progress', 'stock']);
  assert.equal(t[0]?.count, 2);
  assert.equal(t.find((x) => x.key === 'stock')?.count, 3);
  assert.equal(t.find((x) => x.key === 'stock')?.urgent, true);
});

test('low stock alone is not urgent, out of stock is', () => {
  assert.equal(attentionTiles('staff', { ...f, outOfStock: 0 }).find((x) => x.key === 'stock')?.urgent, false);
});

test('a quiet shop has no tiles, and bad numbers count as zero', () => {
  assert.deepEqual(attentionTiles('owner', { requested: 0, confirmed: 0, lowStock: 0, outOfStock: 0, disputed: 0 }), []);
  assert.deepEqual(attentionTiles('owner', { requested: Number.NaN, confirmed: -4, lowStock: 0, outOfStock: 0, disputed: 0 }), []);
});

test('disputes are shown and urgent', () => {
  const d = attentionTiles('manager', { ...f, disputed: 1 }).find((x) => x.key === 'disputes');
  assert.equal(d?.count, 1);
  assert.equal(d?.urgent, true);
});

test('checklist: a new owner has five steps to do', () => {
  const c = setupChecklist('owner', s0);
  assert.deepEqual(c.steps.map((x) => x.key), ['branch', 'products', 'catalogue', 'verify']);
  assert.equal(c.done, 0);
  assert.equal(c.total, 4);
  assert.equal(c.complete, false);
});

test('checklist: steps tick off', () => {
  const c = setupChecklist('owner', { branches: 1, products: PRODUCTS_GOAL, catalogues: 0, verified: true });
  assert.deepEqual(c.steps.filter((x) => x.done).map((x) => x.key), ['branch', 'products', 'verify']);
  assert.equal(setupChecklist('owner', { branches: 1, products: 3, catalogues: 1, verified: true }).complete, true);
  assert.equal(setupChecklist('owner', { ...s0, products: PRODUCTS_GOAL - 1 }).steps.find((x) => x.key === 'products')?.done, false);
});

test('checklist: managers and staff only get steps they may do; only owners verify', () => {
  assert.deepEqual(setupChecklist('manager', s0).steps.map((x) => x.key), ['branch', 'products', 'catalogue']);
  assert.deepEqual(setupChecklist('staff', s0).steps.map((x) => x.key), ['products']);
});

test('sales summary is only for people who may see analytics', () => {
  const a = { periodDays: 7, completedOrders: 4, completedValue: 12500.4, ordersReceived: 6, topListings: [{ id: 'a', title: 'A', completed: 3 }, { id: 'b', title: 'B', completed: 0 }, { id: 'c', title: 'C', completed: 1 }] };
  assert.equal(salesSummary('staff', a), null);
  assert.equal(salesSummary('owner', null), null);
  const s = salesSummary('manager', a);
  assert.equal(s?.revenue, 'K12,500');
  assert.equal(s?.periodLabel, 'last 7 days');
  assert.deepEqual(s?.top.map((x) => x.id), ['a', 'c']);
  assert.equal(s?.empty, false);
  assert.equal(salesSummary('owner', { ...a, ordersReceived: 0, completedOrders: 0, completedValue: 0, topListings: [] })?.empty, true);
});

import { stockCounts } from './dashboard';
test('an item that is out of stock is not also counted as low', () => {
  assert.deepEqual(stockCounts([{ listingId: 'a' }, { listingId: 'b' }, { listingId: 'c' }], [{ listingId: 'c' }]), { lowStock: 2, outOfStock: 1 });
  assert.deepEqual(stockCounts([], []), { lowStock: 0, outOfStock: 0 });
  assert.deepEqual(stockCounts([{ listingId: 'a' }, { listingId: 'a' }], []), { lowStock: 1, outOfStock: 0 });
});
