import assert from 'node:assert/strict';
import test from 'node:test';

import { customerCanRate, customerCanReply, customerStatusLabel, isOverdue, resolutionLabel, ticketFormProblem } from './support';

test('customers see friendly status words', () => {
  assert.equal(customerStatusLabel('escalated'), 'With a senior team member');
  assert.equal(customerStatusLabel('waiting_on_customer'), 'Waiting for your reply');
});

test('ticket form needs a title and some detail', () => {
  assert.notEqual(ticketFormProblem('Hi', 'This is long enough text'), null);
  assert.notEqual(ticketFormProblem('Wrong item', 'short'), null);
  assert.equal(ticketFormProblem('Wrong item', 'The item is not what was described'), null);
});

test('closed tickets take no replies', () => {
  assert.equal(customerCanReply('closed'), false);
  assert.equal(customerCanReply('resolved'), true);
});

test('rating only after real help, once', () => {
  assert.equal(customerCanRate('resolved', 'fixed', null), true);
  assert.equal(customerCanRate('resolved', 'fixed', 4), false);
  assert.equal(customerCanRate('closed', 'customer_withdrew', null), false);
  assert.equal(customerCanRate('open', null, null), false);
});

test('overdue means no first reply past the target', () => {
  const now = new Date('2026-11-23T12:00:00Z');
  assert.equal(isOverdue('2026-11-23T10:00:00Z', false, 'open', now), true);
  assert.equal(isOverdue('2026-11-23T10:00:00Z', true, 'open', now), false);
  assert.equal(isOverdue('2026-11-23T14:00:00Z', false, 'open', now), false);
  assert.equal(isOverdue('2026-11-23T10:00:00Z', false, 'resolved', now), false);
});

test('resolution wording', () => {
  assert.equal(resolutionLabel('refunded'), 'Refunded');
  assert.equal(resolutionLabel('customer_withdrew'), 'Closed by you');
  assert.equal(resolutionLabel(null), '');
});
