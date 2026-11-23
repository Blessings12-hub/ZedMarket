import assert from 'node:assert/strict';
import test from 'node:test';

import { canStartPayment, newPaymentKey, normalisePhone, refundProblem, statusLabel } from './payments';

test('phone numbers are put in one format', () => {
  assert.equal(normalisePhone('0961234567'), '+260961234567');
  assert.equal(normalisePhone('+260 96 123 4567'), '+260961234567');
  assert.equal(normalisePhone('260961234567'), '+260961234567');
  assert.equal(normalisePhone('096123456'), null);
  assert.equal(normalisePhone('+44 7700 900123'), null);
  assert.equal(normalisePhone(''), null);
});

test('payment keys are long enough and differ', () => {
  const a = newPaymentKey(1000, () => 0.123);
  const b = newPaymentKey(1000, () => 0.456);
  assert.ok(a.length >= 8);
  assert.notEqual(a, b);
});

test('only the buyer of a confirmed order with nothing live can start paying', () => {
  assert.equal(canStartPayment('confirmed', 'buyer', []), true);
  assert.equal(canStartPayment('confirmed', 'buyer', [{ status: 'failed' }, { status: 'cancelled' }]), true);
  assert.equal(canStartPayment('confirmed', 'buyer', [{ status: 'pending' }]), false);
  assert.equal(canStartPayment('confirmed', 'buyer', [{ status: 'succeeded' }]), false);
  assert.equal(canStartPayment('requested', 'buyer', []), false);
  assert.equal(canStartPayment('confirmed', 'seller', []), false);
});

test('status wording', () => {
  assert.equal(statusLabel('succeeded'), 'Paid');
  assert.equal(statusLabel('failed'), 'Did not go through');
  assert.equal(statusLabel('succeeded', true), 'Being checked by our team');
});

test('refund form checks', () => {
  assert.equal(refundProblem(0, 100, 'long enough'), 'Enter an amount above zero.');
  assert.match(refundProblem(200, 100, 'long enough') ?? '', /more than is left/);
  assert.equal(refundProblem(50, 100, 'abc'), 'Give a reason.');
  assert.equal(refundProblem(50, 100, 'Order cancelled'), null);
});
