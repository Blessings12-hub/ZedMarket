import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  choiceLabel,
  closesAtFor,
  countsLine,
  isDecided,
  isFinal,
  outcomeExplanation,
  proposalProblem,
  requiredVotes,
  statusLabel,
  stillNeeded,
  timeLeft,
} from './voting';

test('two thirds is rounded up and never down', () => {
  assert.equal(requiredVotes(1), 1);
  assert.equal(requiredVotes(3), 2);
  assert.equal(requiredVotes(4), 3);
  assert.equal(requiredVotes(6), 4);
  assert.equal(requiredVotes(9), 6);
  assert.equal(requiredVotes(10), 7);
  assert.equal(requiredVotes(11), 8);
  assert.equal(requiredVotes(12), 8);
});

test('the threshold is always more than half, so a simple majority can never be enough', () => {
  for (let n = 1; n <= 200; n++) {
    const need = requiredVotes(n);
    assert.ok(need * 2 > n, `${need} of ${n} must be more than half`);
    assert.ok(need <= n, `${need} cannot exceed ${n}`);
    // Both sides can never reach the threshold together: one vote each.
    assert.ok(need * 2 > n, 'both sides cannot both reach it');
  }
});

test('bad eligible counts give no threshold', () => {
  assert.equal(requiredVotes(0), 0);
  assert.equal(requiredVotes(-3), 0);
  assert.equal(requiredVotes(2.5), 0);
});

test('labels cover every status and choice', () => {
  assert.equal(statusLabel('active'), 'Open for voting');
  assert.equal(statusLabel('pending'), 'Scheduled');
  assert.equal(statusLabel('something_new'), 'something_new');
  assert.equal(choiceLabel('for'), 'For');
  assert.equal(choiceLabel(null), 'Not voted');
});

test('which statuses are final or decided', () => {
  assert.equal(isFinal('active'), false);
  assert.equal(isFinal('cancelled'), true);
  assert.equal(isDecided('cancelled'), false);
  assert.equal(isDecided('unresolved'), true);
});

test('outcome text names the real threshold and never talks about a majority winning', () => {
  assert.match(outcomeExplanation('approved', 6, 9), /6 of 9/);
  assert.match(outcomeExplanation('rejected', 6, 9), /against/);
  assert.match(outcomeExplanation('unresolved', 6, 9), /simple majority is not enough/);
  assert.equal(outcomeExplanation('active', 6, 9), '');
});

test('hidden counts stay hidden', () => {
  const hidden = { for: null, against: null, abstain: null, hidden: true };
  assert.match(countsLine(hidden), /hidden/);
  assert.equal(stillNeeded(hidden, 6), null);
  const shown = { for: 4, against: 1, abstain: 2, hidden: false };
  assert.equal(countsLine(shown), 'For 4 · Against 1 · Abstain 2');
  assert.deepEqual(stillNeeded(shown, 6), { forNeeds: 2, againstNeeds: 5 });
  assert.deepEqual(stillNeeded({ ...shown, for: 8 }, 6), { forNeeds: 0, againstNeeds: 5 });
});

test('time left reads naturally', () => {
  const now = new Date('2026-01-01T10:00:00Z');
  assert.equal(timeLeft(null, now), '');
  assert.equal(timeLeft('2026-01-01T09:59:00Z', now), 'Closing now');
  assert.equal(timeLeft('2026-01-01T10:20:00Z', now), '20 min left');
  assert.equal(timeLeft('2026-01-01T15:00:00Z', now), '5 h left');
  assert.equal(timeLeft('2026-01-04T10:00:00Z', now), '3 days left');
});

test('the proposal form is checked before sending', () => {
  const ok = { title: 'Change the review window', description: 'Reviews should close after 7 days.', reason: 'Disputes arrive too late.', confirmedNoOverride: true };
  assert.equal(proposalProblem(ok), null);
  assert.notEqual(proposalProblem({ ...ok, title: 'abc' }), null);
  assert.notEqual(proposalProblem({ ...ok, description: 'short' }), null);
  assert.notEqual(proposalProblem({ ...ok, reason: '' }), null);
  assert.notEqual(proposalProblem({ ...ok, confirmedNoOverride: false }), null);
  assert.notEqual(proposalProblem({ ...ok, title: 'x'.repeat(121) }), null);
});

test('closing time is counted forward from now', () => {
  const now = new Date('2026-01-01T00:00:00Z');
  assert.equal(closesAtFor(24, now), '2026-01-02T00:00:00.000Z');
});
