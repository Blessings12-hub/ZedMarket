import assert from 'node:assert/strict';
import test from 'node:test';

import { canChangeAccountState, canReadTrust, canReviewApplications, canSeeTrustAudit } from './admin';
import { auditActionLabel, auditDetail, nextAccountStates, stateActionLabel } from './trustAdmin';

test('who sees which parts of User & Trust Management', () => {
  assert.equal(canReadTrust(['support']), true);
  assert.equal(canReadTrust(['moderator']), true);
  assert.equal(canReadTrust(['finance']), false);
  assert.equal(canReadTrust(['tech_admin']), false);
  assert.equal(canReviewApplications(['moderator']), false);
  assert.equal(canReviewApplications(['support']), true);
  assert.equal(canChangeAccountState(['support']), false);
  assert.equal(canChangeAccountState(['moderator']), true);
  assert.equal(canSeeTrustAudit(['tech_admin']), true);
  assert.equal(canSeeTrustAudit(['finance']), false);
});

test('audit entries read as plain sentences', () => {
  assert.equal(auditActionLabel('document.viewed'), 'Document opened');
  assert.equal(auditActionLabel('admin_role.granted'), 'admin role granted');
  assert.equal(auditDetail('identity.reviewed', { approved: false, note: 'Blurry' }), 'Rejected. Note: Blurry');
  assert.equal(auditDetail('business.reviewed', { approved: true }), 'Approved.');
  assert.equal(auditDetail('account.state_changed', { state: 'suspended', reason: 'Fake documents' }), 'Set to suspended. Reason: Fake documents');
  assert.equal(auditDetail('document.viewed', { kind: 'business' }), 'Business document.');
  assert.equal(auditDetail('anything.else', null), '');
});

test('account state choices exclude the current state', () => {
  assert.deepEqual(nextAccountStates('active'), ['restricted', 'suspended']);
  assert.deepEqual(nextAccountStates('suspended'), ['active', 'restricted']);
  assert.equal(stateActionLabel('active'), 'Reinstate');
});
