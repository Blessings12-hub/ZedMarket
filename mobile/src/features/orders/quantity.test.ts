import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseHandedOver, parseQuantity, quantityLine, suggestBranch } from './quantity';

test('a one-off item is always quantity 1', () => {
  assert.deepEqual(parseQuantity('', null), { quantity: 1 });
  assert.deepEqual(parseQuantity('5', null), { quantity: 1 });
});
test('counted stock: readable errors, and never more than is available', () => {
  assert.deepEqual(parseQuantity('3', 10), { quantity: 3 });
  assert.deepEqual(parseQuantity(' 3 ', 10), { quantity: 3 });
  assert.match((parseQuantity('abc', 10) as { error: string }).error, /whole number/);
  assert.match((parseQuantity('', 10) as { error: string }).error, /whole number/);
  assert.match((parseQuantity('0', 10) as { error: string }).error, /at least 1/);
  assert.match((parseQuantity('2.5', 10) as { error: string }).error, /whole number/);
  assert.equal((parseQuantity('11', 10) as { error: string }).error, 'Only 10 available right now. Order 10 or fewer.');
  assert.match((parseQuantity('1', 0) as { error: string }).error, /None are available/);
  assert.match((parseQuantity('1001', 5000) as { error: string }).error, /between 1 and 1000/);
});
test('the quantity line appears only when it matters', () => {
  assert.equal(quantityLine(1, null), null);
  assert.equal(quantityLine(1, 1), null);
  assert.equal(quantityLine(4, null), 'Quantity 4');
  assert.equal(quantityLine(4, 4), 'Quantity 4');
  assert.equal(quantityLine(4, 3), 'Quantity 4 ordered, 3 handed over');
});
test('handed over: empty means all, and the range matches the database message', () => {
  assert.deepEqual(parseHandedOver('', 4), { quantity: 4 });
  assert.deepEqual(parseHandedOver('3', 4), { quantity: 3 });
  assert.equal((parseHandedOver('0', 4) as { error: string }).error, 'Say how many were handed over: between 1 and 4.');
  assert.equal((parseHandedOver('5', 4) as { error: string }).error, 'Say how many were handed over: between 1 and 4.');
  assert.match((parseHandedOver('x', 4) as { error: string }).error, /whole number/);
});
test('the branch suggestion picks the one with most free stock that fits', () => {
  const o = [{ id: 'a', name: 'A', available: 2 }, { id: 'b', name: 'B', available: 7 }, { id: 'c', name: 'C', available: 4 }];
  assert.equal(suggestBranch(o, 3), 'b');
  assert.equal(suggestBranch(o, 8), null);
  assert.equal(suggestBranch([], 1), null);
});
