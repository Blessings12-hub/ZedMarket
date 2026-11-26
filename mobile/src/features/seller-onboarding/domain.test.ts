import assert from 'node:assert/strict';
import test from 'node:test';

import { canEdit, canStartOver, emptyForm, formOpen, isFinished, missingBeforeSend, requiredDocs, showsSavedAnswers, staffActions, STATUS_HELP, STATUS_LABEL, type Form } from './domain';

const full = (): Form => ({
  ...emptyForm(), legal_name: 'Anna Mwansa', nationality: 'Zambian', is_adult: true, id_number: '123456/10/1',
  residential_address: 'Plot 5 Kabulonga', selling_location_id: 1, category_ids: [1], sourcing_type: 'import',
  sourcing_info: 'Bought from a supplier', experience_level: 'none', expected_catalogue_size: '10',
  returns_arrangements: 'Seven days', customer_service_arrangements: 'Replies daily',
  declarations: { sells_only_legal_goods: true, no_counterfeit_or_stolen: true, information_is_true: true, will_honour_returns: true },
});
const ok = { agreementAccepted: true, documentKinds: requiredDocs('nrc'), contactVerified: true };

test('a complete application has nothing missing', () => assert.deepEqual(missingBeforeSend(full(), ok), []));
test('an empty form lists what is missing, including documents and agreement', () => {
  const m = missingBeforeSend(emptyForm(), { agreementAccepted: false, documentKinds: [], contactVerified: false });
  assert.ok(m.length >= 10);
  assert.ok(m.some((x) => x.includes('Accept the seller agreement')));
  assert.ok(m.some((x) => x.startsWith('Upload')));
});
test('passports need different documents from an NRC', () => {
  assert.ok(requiredDocs('nrc').includes('id_back'));
  assert.ok(!requiredDocs('passport').includes('id_back'));
  assert.ok(requiredDocs('passport').includes('passport_page'));
});
test('unverified contact details block sending', () => {
  assert.ok(missingBeforeSend(full(), { ...ok, contactVerified: false })[0]?.includes('email'));
});
test('only a draft can be edited', () => {
  assert.equal(canEdit(null), true);
  assert.equal(canEdit('draft'), true);
  for (const s of ['submitted', 'under_review', 'approved', 'rejected', 'suspended'] as const) assert.equal(canEdit(s), false);
});
test('reviewer actions follow the state', () => {
  assert.deepEqual(staffActions('submitted', { mine: false, assigned: false }), ['claim']);
  assert.deepEqual(staffActions('under_review', { mine: false, assigned: true }), []);
  assert.ok(staffActions('under_review', { mine: true, assigned: true }).includes('approve'));
  assert.deepEqual(staffActions('rejected', { mine: true, assigned: true }), []);
  assert.deepEqual(staffActions('suspended', { mine: false, assigned: false }), ['reinstate']);
});

test('after a rejected, withdrawn or deleted application the person can start a new one', () => {
  for (const s of ['rejected', 'closed'] as const) {
    assert.equal(canStartOver(s), true, s);
    assert.equal(formOpen(s, 'none'), true, s);
    assert.equal(showsSavedAnswers(s), false, `${s} must not refill the new form`);
  }
  assert.equal(formOpen(null, 'none'), true);
  assert.equal(formOpen('draft', 'none'), true);
});

test('the form stays closed while an application is being reviewed or a seller is approved, paused or removed', () => {
  for (const s of ['submitted', 'under_review', 'additional_information_required', 'approved', 'suspended', 'revoked'] as const) {
    assert.equal(formOpen(s, 'none'), false, s);
  }
  // an approved, suspended or revoked seller never gets the form, whatever the last application says
  for (const st of ['active', 'suspended', 'revoked']) assert.equal(formOpen(null, st), false, st);
});

test('a deleted selling account is a finished state with its own words', () => {
  assert.equal(isFinished('closed'), true);
  assert.equal(STATUS_LABEL.closed, 'Closed');
  assert.match(STATUS_HELP.closed, /apply again/i);
  assert.match(STATUS_HELP.closed, /from the start/i);
  assert.deepEqual(staffActions('closed', { mine: true, assigned: true }), []);
});
