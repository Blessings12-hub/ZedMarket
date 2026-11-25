import assert from 'node:assert/strict';
import test from 'node:test';

import { movePhoto, newPrice, parseNumber, parseWhole, sellerState, toggle } from './sellerTools';

test('what each listing state tells the seller', () => {
  assert.equal(sellerState('active', 'approved').label, 'Live');
  assert.equal(sellerState('active', 'pending').label, 'Waiting for review');
  assert.equal(sellerState('active', 'rejected').tone, 'bad');
  assert.equal(sellerState('draft', 'approved').label, 'Draft');
  assert.equal(sellerState('unavailable', 'approved').label, 'Paused');
});

test('price preview matches the server (two decimals, never zero or negative)', () => {
  assert.equal(newPrice(100, 'percent', 10), 110);
  assert.equal(newPrice(100, 'amount', -10), 90);
  assert.equal(newPrice(100, 'set', 99.999), 100);
  assert.equal(newPrice(100, 'amount', -100), null);
  assert.equal(newPrice(100, 'percent', -100), null);
  assert.equal(newPrice(33.33, 'percent', 10), 36.66);
  assert.equal(newPrice(100, 'set', Number.NaN), null);
});

test('numbers are read strictly', () => {
  assert.equal(parseNumber('1,250.50'), 1250.5);
  assert.equal(parseNumber('-5'), -5);
  assert.equal(parseNumber('abc'), null);
  assert.equal(parseNumber(''), null);
  assert.equal(parseWhole('3'), 3);
  assert.equal(parseWhole('3.5'), null);
});

test('selection toggles and stops at the cap', () => {
  assert.deepEqual(toggle([], 'a'), ['a']);
  assert.deepEqual(toggle(['a', 'b'], 'a'), ['b']);
  assert.deepEqual(toggle(['a', 'b'], 'c', 2), ['a', 'b']);
});

test('photos move one place and never off the ends', () => {
  assert.deepEqual(movePhoto(['a', 'b', 'c'], 2, -1), ['a', 'c', 'b']);
  assert.deepEqual(movePhoto(['a', 'b', 'c'], 0, -1), ['a', 'b', 'c']);
  assert.deepEqual(movePhoto(['a', 'b', 'c'], 2, 1), ['a', 'b', 'c']);
  assert.deepEqual(movePhoto(['a'], 0, 1), ['a']);
});
