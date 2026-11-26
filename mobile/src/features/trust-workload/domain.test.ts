import assert from 'node:assert/strict';
import { test } from 'node:test';
import { needsAttention, normalizeAccess, normalizeWorkload } from './domain';

test('a short or odd answer still gives every count', () => {
  const w = normalizeWorkload({ kinds: { seller: { submitted: '2' } } });
  assert.equal(w.seller.submitted, 2);
  assert.equal(w.business.overdue, 0);
  assert.equal(w.escalationDueHours, 24);
  assert.deepEqual(w.officers, []);
});
test('an empty answer is an error, not a silent zero', () => {
  assert.throws(() => normalizeWorkload(null));
});
test('access rows tolerate nulls and non-arrays', () => {
  assert.deepEqual(normalizeAccess(null), []);
  assert.equal(normalizeAccess([{ officer_id: "a", document_opens: "31", flagged: true }])[0]?.documentOpens, 31);
});
test('attention adds overdue, escalated and waiting for a second officer', () => {
  assert.equal(needsAttention({ submitted: 9, under_review: 9, info_requested: 9, escalated: 1, overdue: 2, awaiting_second: 3, unassigned: 9 }), 6);
});
