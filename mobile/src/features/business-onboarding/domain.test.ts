import assert from 'node:assert/strict';
import test from 'node:test';

import { businessStateLine, emptyBizForm, missingBeforeSend, ownershipTotal, registrationBadge, requiredBusinessDocs, type BizForm, type Party } from './domain';

const full = (): BizForm => ({
  ...emptyBizForm(), legal_name: 'Zed Phones Limited', business_type: 'limited_company', pacra_number: '120200001234', pacra_registered_on: '2018-03-01',
  tpin: '1002003004', physical_address: 'Plot 12 Cairo Road', selling_location_id: 1, phone: '+260971000111', email: 'a@b.co', category_ids: [1],
  expected_catalogue_size: '40', rep_name: 'Owner One', rep_role: 'Director', rep_id_number: '111111/10/1',
  declarations: { information_is_true: true, authorised_to_apply: true, sells_only_legal_goods: true, no_counterfeit_or_stolen: true, will_honour_returns: true },
});
const parties = (): Party[] => [
  { kind: 'director', full_name: 'Owner One', nationality: 'Zambian', ownership_pct: '', id_number: '' },
  { kind: 'beneficial_owner', full_name: 'Owner One', nationality: 'Zambian', ownership_pct: '60', id_number: '' },
  { kind: 'beneficial_owner', full_name: 'Mary Banda', nationality: 'Zambian', ownership_pct: '40', id_number: '' },
];
const ok = { agreementAccepted: true, documentKinds: requiredBusinessDocs('registered', true), contactVerified: true };

test('a complete registered business has nothing missing', () => assert.deepEqual(missingBeforeSend(full(), parties(), ok), []));
test('owners must add up to 100%', () => {
  assert.equal(ownershipTotal(parties()), 100);
  const m = missingBeforeSend(full(), parties().slice(0, 2), ok);
  assert.ok(m.some((x) => x.includes('100%')));
});
test('a representative who is not a director needs an authority letter', () => {
  assert.ok(requiredBusinessDocs('registered', false).includes('authority_letter'));
  assert.ok(!requiredBusinessDocs('registered', true).includes('authority_letter'));
});
test('an informal trader is asked different questions and is never badged as registered', () => {
  const f: BizForm = { ...full(), route: 'informal_trader', business_type: '', pacra_number: '', pacra_registered_on: '', tpin: '', trading_place: 'Soweto Market stall 14', years_trading: '4' };
  assert.deepEqual(missingBeforeSend(f, [], { ...ok, documentKinds: requiredBusinessDocs('informal_trader', true) }), []);
  assert.equal(registrationBadge('informal_trader', true), 'Verified informal trader');
  assert.equal(registrationBadge('registered', true), 'Verified registered business');
  assert.equal(registrationBadge('registered', false), null);
});
test('the owner is told plainly where the business stands', () => {
  assert.ok(businessStateLine('none', null).includes('nothing goes live'));
  assert.ok(businessStateLine('active', 'approved').includes('Verified'));
  assert.ok(businessStateLine('suspended', 'suspended').includes('suspended'));
  assert.ok(businessStateLine('none', 'under_review').includes('cannot publish'));
});

import { draftProblems, isRealDate, requiredFields, bizFormOpen, showsSavedBizAnswers } from './domain';
import { loadMine, MalformedResponseError, normalizeMine } from './mine';
import { buildBusinessScreen, formFromApplication } from './view';

const mineAnswer = (over: Record<string, unknown> = {}) => ({
  publish_state: 'none', registration_kind: null, application: null, parties: [], branches: [], permits: [], documents: [], requests: [], history: [], ...over,
});
const bizApp = (over: Record<string, unknown> = {}) => ({ id: 'a1', status: 'draft', required_documents: ['pacra_certificate'], agreement_accepted: false, route: 'registered', ...over });
const quiet = () => {};

test('REGRESSION: an old-style short answer (no lists) must not crash the screen', () => {
  const short = { publish_state: 'none', application: null };
  const m = normalizeMine(short);
  assert.deepEqual([m.documents, m.requests, m.history, m.parties, m.branches, m.permits], [[], [], [], [], [], []]);
  assert.doesNotThrow(() => buildBusinessScreen(m));
  assert.doesNotThrow(() => formFromApplication(m));
});
test('missing, null or wrongly typed lists become empty lists', () => {
  for (const bad of [undefined, null, 'x', 7, {}]) {
    const m = normalizeMine(mineAnswer({ documents: bad, requests: bad, history: bad, parties: bad, branches: bad, permits: bad }));
    assert.deepEqual([m.documents, m.requests, m.history, m.parties, m.branches, m.permits], [[], [], [], [], [], []]);
  }
});
test('an unknown publish state or kind becomes the safe default, never "active"', () => {
  const m = normalizeMine(mineAnswer({ publish_state: 'verified!!', registration_kind: 'company' }));
  assert.equal(m.publish_state, 'none');
  assert.equal(m.registration_kind, null);
  assert.equal(buildBusinessScreen(m).verified, false);
});
test('a broken answer throws instead of showing an empty success', async () => {
  for (const raw of [null, undefined, 'oops', 5, [], { application: { id: 1, status: 'draft' } }, { application: { id: 'a', status: 'wat' } }]) {
    assert.throws(() => normalizeMine(raw), MalformedResponseError);
  }
  await assert.rejects(loadMine(async () => ({ data: null, error: null }), quiet), MalformedResponseError);
  const boom = { message: 'permission denied' };
  await assert.rejects(loadMine(async () => ({ data: null, error: boom }), quiet), (e) => e === boom);
  await assert.rejects(loadMine(async () => { throw new Error('offline'); }, quiet), /offline/);
});
test('a complete answer is read as is, with ownership percentages kept as text for the form', () => {
  const m = normalizeMine(mineAnswer({ application: bizApp({ legal_name: 'Zed Phones Limited' }), parties: [{ kind: 'beneficial_owner', full_name: 'Mary Banda', nationality: 'Zambian', ownership_pct: 40, id_number: null }] }));
  assert.equal(m.application?.legal_name, 'Zed Phones Limited');
  assert.equal(m.parties[0]?.ownership_pct, '40');
  assert.equal(m.parties[0]?.id_number, '');
});
test('rows without an id or a name are dropped, not shown as blanks', () => {
  const m = normalizeMine(mineAnswer({ documents: [{ kind: 'x' }, { id: 'd1', kind: 'permit' }], parties: [{ kind: 'boss', full_name: 'Abc' }, { kind: 'director' }] }));
  assert.equal(m.documents.length, 1);
  assert.equal(m.parties.length, 0);
});

test('draftProblems matches the database limits and names the answer', () => {
  assert.deepEqual(draftProblems(emptyBizForm()), [], 'an empty draft is fine');
  const bad = { ...emptyBizForm(), legal_name: 'AB', phone: 'abc', email: 'nope', pacra_registered_on: '2020-13-45', expected_catalogue_size: '0', tpin: '12' };
  const p = draftProblems(bad);
  assert.ok(p.some((x) => x.startsWith('The legal name must be 3 to 150')));
  assert.ok(p.some((x) => x.includes('phone number')));
  assert.ok(p.some((x) => x.includes('email')));
  assert.ok(p.some((x) => x.includes('registration date')));
  assert.ok(p.some((x) => x.includes('number of products')));
  assert.ok(p.some((x) => x.startsWith('The TPIN must be 5 to 20')));
  assert.ok(draftProblems(emptyBizForm(), [{ kind: 'beneficial_owner', full_name: 'Al', nationality: '', ownership_pct: '', id_number: '1' }]).length >= 3);
});
test('the form never accepts less than the database requires before sending', () => {
  const f = { ...full(), legal_name: 'AB' };
  assert.ok(missingBeforeSend(f, parties(), ok).includes('The legal name of the business'));
  assert.ok(missingBeforeSend({ ...full(), pacra_registered_on: '2020-02-31' }, parties(), ok).some((x) => x.includes('registration date')));
  assert.ok(missingBeforeSend({ ...full(), phone: '12345' }, parties(), ok).includes('A phone number'));
});
test('dates are checked as real dates', () => {
  assert.equal(isRealDate('2020-02-29'), true);
  assert.equal(isRealDate('2021-02-29'), false);
  assert.equal(isRealDate('2020-13-01'), false);
  assert.equal(isRealDate('1/1/2020'), false);
});
test('the starred (required) fields follow the route', () => {
  const reg = requiredFields('registered');
  const inf = requiredFields('informal_trader');
  for (const k of ['legal_name', 'documents', 'agreement', 'rep_id_number', 'phone', 'email']) assert.ok(reg.includes(k) && inf.includes(k), k);
  for (const k of ['pacra_number', 'tpin', 'directors', 'beneficial_owners', 'business_type']) assert.ok(reg.includes(k) && !inf.includes(k), k);
  for (const k of ['trading_place', 'years_trading']) assert.ok(inf.includes(k) && !reg.includes(k), k);
  for (const k of ['trading_name', 'ownership_summary', 'branches', 'permits']) assert.ok(!reg.includes(k) && !inf.includes(k), `${k} is optional`);
});
test('the form opens for a first application, a draft or a fresh start, never for a verified or pending business', () => {
  assert.equal(bizFormOpen(null, 'none'), true);
  assert.equal(bizFormOpen('draft', 'none'), true);
  assert.equal(bizFormOpen('rejected', 'none'), true);
  for (const s of ['submitted', 'under_review', 'additional_information_required'] as const) assert.equal(bizFormOpen(s, 'none'), false, s);
  assert.equal(bizFormOpen(null, 'active'), false);
  assert.equal(bizFormOpen('draft', 'suspended'), false);
  assert.equal(showsSavedBizAnswers('rejected'), false);
  assert.equal(showsSavedBizAnswers('draft'), true);
});
test('a rejected application starts a fresh empty form; a draft keeps its answers', () => {
  const rej = formFromApplication(normalizeMine(mineAnswer({ application: bizApp({ status: 'rejected', legal_name: 'Old Name Ltd' }) })));
  assert.equal(rej.form.legal_name, '');
  const dr = formFromApplication(normalizeMine(mineAnswer({ application: bizApp({ legal_name: 'Kept Name Ltd', rep_is_director: false }) })));
  assert.equal(dr.form.legal_name, 'Kept Name Ltd');
  assert.equal(dr.form.rep_is_director, false);
});
test('the screen model: documents appear only for a saved draft; open requests are listed', () => {
  assert.equal(buildBusinessScreen(normalizeMine(mineAnswer())).showDocuments, false);
  assert.equal(buildBusinessScreen(normalizeMine(mineAnswer())).isFirstTime, true);
  assert.equal(buildBusinessScreen(normalizeMine(mineAnswer({ application: bizApp() }))).showDocuments, true);
  const m = buildBusinessScreen(normalizeMine(mineAnswer({ application: bizApp({ status: 'additional_information_required' }), requests: [{ id: 'r1', status: 'open', message: 'x' }, { id: 'r2', status: 'answered', message: 'y' }] })));
  assert.deepEqual(m.openRequests.map((r) => r.id), ['r1']);
  assert.equal(m.editable, false);
});
