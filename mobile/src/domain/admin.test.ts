import assert from 'node:assert/strict';
import { test } from 'node:test';

import { canHandleReports, canManageTeam, canModerate, canSupport, cleanTotpCode, reasonProblem, staffAccessStep } from './admin';

test('people with no staff role never get past the first step', () => {
  assert.equal(staffAccessStep([], 'aal2', 'aal2'), 'not_staff');
});

test('staff are sent to enrol, verify or in depending on two-factor state', () => {
  assert.equal(staffAccessStep(['moderator'], 'aal1', 'aal1'), 'enrol');
  assert.equal(staffAccessStep(['moderator'], 'aal1', 'aal2'), 'verify');
  assert.equal(staffAccessStep(['moderator'], 'aal2', 'aal2'), 'ready');
  assert.equal(staffAccessStep(['support'], undefined, undefined), 'enrol');
});

test('roles are kept separate', () => {
  assert.equal(canModerate(['support']), false);
  assert.equal(canModerate(['moderator']), true);
  assert.equal(canHandleReports(['support']), true);
  assert.equal(canHandleReports(['finance']), false);
});

test('a reason is required and has a ceiling', () => {
  assert.notEqual(reasonProblem('  '), null);
  assert.notEqual(reasonProblem('ab'), null);
  assert.equal(reasonProblem('Fake photos'), null);
  assert.notEqual(reasonProblem('x'.repeat(501)), null);
});

test('authenticator codes keep only six digits', () => {
  assert.equal(cleanTotpCode('123 456'), '123456');
  assert.equal(cleanTotpCode('12-34-56-78'), '123456');
});

test('support and team tools are limited to their own roles', () => {
  assert.equal(canSupport(['moderator']), false);
  assert.equal(canSupport(['support']), true);
  assert.equal(canManageTeam(['moderator', 'support']), false);
  assert.equal(canManageTeam(['tech_admin']), true);
});
