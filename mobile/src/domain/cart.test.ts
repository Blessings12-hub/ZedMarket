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

test('quantity: old carts count as 1, bad values are repaired, and the total follows the quantity', async () => {
  const { effectiveQuantity, setCartQuantity, MAX_CART_QUANTITY } = await import('./cart');
  const old = item('a', 10);
  assert.equal(effectiveQuantity(old, 5), 1);
  assert.equal(effectiveQuantity({ ...old, quantity: 3 }, 5), 3);
  assert.equal(effectiveQuantity({ ...old, quantity: 9 }, 5), 5, 'never more than is available');
  assert.equal(effectiveQuantity({ ...old, quantity: 3 }, null), 1, 'a one-off item is always 1');
  assert.equal(effectiveQuantity({ ...old, quantity: 3 }, undefined), 1, 'unknown stock is treated as 1');
  assert.equal(effectiveQuantity({ ...old, quantity: 3 }, 0), 1);
  assert.equal(setCartQuantity([old], 'a', 2.5)[0]?.quantity, 1);
  assert.equal(setCartQuantity([old], 'a', -4)[0]?.quantity, 1);
  assert.equal(setCartQuantity([old], 'a', 99999)[0]?.quantity, MAX_CART_QUANTITY);
  assert.equal(cartTotal([{ ...item('a', 10), quantity: 3 }, item('b', 5)], { a: 5, b: null }), 35);
  const c = parseCart(JSON.stringify([{ ...item('a'), quantity: 'lots' }, { ...item('b'), quantity: 4 }, item('c')]));
  assert.deepEqual(c.map((x) => x.quantity), [1, 4, 1]);
});
