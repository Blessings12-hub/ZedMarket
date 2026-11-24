import assert from 'node:assert/strict';
import test from 'node:test';

import { addToCart, cartTotal, inCart, MAX_CART_ITEMS, parseCart, removeFromCart, type CartItem } from './cart';

const item = (id: string, price = 100): CartItem => ({ listingId: id, title: `Item ${id}`, price, sellerName: 'S', imagePath: null, addedAt: '' });

test('adding the same listing twice keeps one copy', () => {
  assert.equal(addToCart(addToCart([], item('a')), item('a')).length, 1);
});

test('remove and membership', () => {
  const c = addToCart(addToCart([], item('a')), item('b'));
  assert.ok(inCart(c, 'a'));
  const r = removeFromCart(c, 'a');
  assert.ok(!inCart(r, 'a') && inCart(r, 'b'));
});

test('total adds prices without float drift', () => {
  assert.equal(cartTotal([item('a', 0.1), item('b', 0.2)]), 0.3);
  assert.equal(cartTotal([]), 0);
});

test('the cart has a size limit', () => {
  let c: CartItem[] = [];
  for (let i = 0; i < MAX_CART_ITEMS + 5; i++) c = addToCart(c, item(String(i)));
  assert.equal(c.length, MAX_CART_ITEMS);
});

test('damaged stored data becomes an empty or cleaned cart', () => {
  assert.deepEqual(parseCart(null), []);
  assert.deepEqual(parseCart('not json'), []);
  assert.deepEqual(parseCart('{"a":1}'), []);
  const c = parseCart(JSON.stringify([item('a'), { listingId: 'x' }, item('a'), { ...item('b'), price: 'free' }]));
  assert.deepEqual(c.map((i) => i.listingId), ['a']);
});
