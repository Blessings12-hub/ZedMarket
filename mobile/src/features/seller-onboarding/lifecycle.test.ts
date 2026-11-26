import assert from 'node:assert/strict';
import test from 'node:test';

import { canUseSellingScreens, showOrdersTab } from '../../domain/sellerAccess';
import { SELLER_CLOSE, SELLER_CLOSE_REVOKED, SELLER_CLOSE_SUSPENDED } from '../../domain/closeAccount';
import { friendlyError } from '../../lib/errors';
import { readSellerApplication } from '../account-hub/sellerSummary';
import { draftProblems, emptyForm, missingBeforeSend, requiredDocs, STATUS_LABEL, type Form } from './domain';
import { loadMine, MalformedResponseError, normalizeMine } from './mine';
import { buildSellerScreen, formFromApplication } from './view';

const app = (over: Record<string, unknown> = {}) => ({ id: 'a1', status: 'draft', required_documents: ['id_front'], agreement_accepted: false, ...over });
const answer = (over: Record<string, unknown> = {}) => ({ seller_status: 'none', application: app(), documents: [], requests: [], history: [], ...over });
const quiet = () => {};

// The exact shape the old database function sent to a buyer who never applied.
const OLD_BUYER_ANSWER = { seller_status: 'none', application: null };

test('REGRESSION: the old two-part answer used to crash on .filter, and is now safe', () => {
  const raw = OLD_BUYER_ANSWER as unknown as { documents: { kind: string }[] };
  assert.throws(() => raw.documents.filter((d) => d.kind), TypeError, 'this is the crash the screen used to hit');
  const m = normalizeMine(OLD_BUYER_ANSWER);
  assert.deepEqual(m.documents.filter((d) => d.kind), []);
  assert.deepEqual(m.requests.filter((r) => r.status === 'open'), []);
  assert.deepEqual(m.history.filter((h) => h.event), []);
  assert.doesNotThrow(() => buildSellerScreen(m));
});

test('the new complete answer for a first-time applicant is read as is', () => {
  const m = normalizeMine({ seller_status: 'none', application: null, documents: [], requests: [], history: [] });
  assert.equal(m.application, null);
  assert.deepEqual([m.documents, m.requests, m.history], [[], [], []]);
});

test('missing, null or wrongly typed lists become empty lists', () => {
  for (const bad of [undefined, null, 'x', 7, {}]) {
    const m = normalizeMine({ seller_status: 'none', application: null, documents: bad, requests: bad, history: bad });
    assert.deepEqual([m.documents, m.requests, m.history], [[], [], []]);
  }
});

test('a missing or invalid seller status is safe: not a seller', () => {
  for (const bad of [undefined, null, 'wizard', 5]) assert.equal(normalizeMine({ ...answer(), seller_status: bad }).seller_status, 'none');
});

test('unusable list items are dropped instead of crashing', () => {
  const m = normalizeMine(answer({ documents: [null, { kind: 'x' }, { id: 'd1', kind: 'id_front' }], requests: ['x', { id: 'r1', status: 'open' }], history: [{}, { event: 'submitted' }] }));
  assert.equal(m.documents.length, 1);
  assert.equal(m.requests[0]?.document_kinds.length, 0);
  assert.equal(m.history.length, 1);
});

test('a broken answer is an error, not a quiet empty success', () => {
  for (const bad of [null, undefined, 'oops', [], 3]) assert.throws(() => normalizeMine(bad), MalformedResponseError);
  assert.throws(() => normalizeMine(answer({ application: { id: 'a1', status: 'mystery' } })), MalformedResponseError);
  assert.throws(() => normalizeMine(answer({ application: { status: 'draft' } })), MalformedResponseError);
});

test('every status the database can send is known to the app', () => {
  const dbStatuses = ['draft', 'submitted', 'under_review', 'additional_information_required', 'approved', 'rejected', 'suspended', 'revoked', 'closed'];
  for (const s of dbStatuses) {
    assert.ok(STATUS_LABEL[s as keyof typeof STATUS_LABEL], s);
    assert.doesNotThrow(() => buildSellerScreen(normalizeMine(answer({ application: app({ status: s }) }))), s);
  }
});

test('Ordinary buyer opens Seller Status: the screen is built, with an empty state, and no selling tools', () => {
  const v = buildSellerScreen(normalizeMine(OLD_BUYER_ANSWER));
  assert.equal(v.isFirstTime, true);
  assert.equal(v.mode, 'application');
  assert.equal(v.close, null);
  assert.equal(canUseSellingScreens({ status: 'none', hasBusiness: false }), false);
  assert.equal(showOrdersTab('none'), false);
});

test('Ordinary buyer starts registration: the form is open and empty, with no documents yet', () => {
  const v = buildSellerScreen(normalizeMine(OLD_BUYER_ANSWER));
  assert.equal(v.editable, true);
  assert.equal(v.showDocuments, false);
  assert.deepEqual(formFromApplication(normalizeMine(OLD_BUYER_ANSWER)), emptyForm());
});

test('User saves a draft, then reopens it: the saved answers load and documents can be added', () => {
  const m = normalizeMine(answer({ application: app({ legal_name: 'Anna Mwansa', nationality: 'Zambian', expected_catalogue_size: 20, category_ids: [1, 2], is_adult: true }) }));
  const f = formFromApplication(m);
  assert.equal(f.legal_name, 'Anna Mwansa');
  assert.equal(f.expected_catalogue_size, '20');
  assert.deepEqual(f.category_ids, [1, 2]);
  const v = buildSellerScreen(m);
  assert.equal(v.editable, true);
  assert.equal(v.showDocuments, true);
});

test('Draft problems are named before anything is sent, and match the database limits', () => {
  const f: Form = { ...emptyForm(), legal_name: 'A', residential_address: 'Lusaka', id_number: '12', returns_arrangements: 'ok', expected_catalogue_size: 'lots' };
  const p = draftProblems(f);
  assert.ok(p.includes('Your full legal name must be 3 to 120 characters.'));
  assert.ok(p.includes('Your residential address must be 10 to 300 characters.'));
  assert.ok(p.includes('Your ID number must be 5 to 30 characters.'));
  assert.ok(p.includes('The number of products must be between 1 and 100000.'));
  assert.deepEqual(draftProblems(emptyForm()), [], 'an empty draft is allowed');
});

test('The app no longer accepts answers the database would refuse (address, returns, customer service, ID number)', () => {
  const ok = { agreementAccepted: true, documentKinds: requiredDocs('nrc'), contactVerified: true };
  const base: Form = {
    ...emptyForm(), legal_name: 'Anna Mwansa', nationality: 'Zambian', is_adult: true, id_number: '123456/10/1', residential_address: 'Plot 5 Kabulonga',
    selling_location_id: 1, category_ids: [1], sourcing_type: 'import', sourcing_info: 'Bought from a supplier', experience_level: 'none',
    expected_catalogue_size: '10', returns_arrangements: 'Seven days', customer_service_arrangements: 'Replies daily',
    declarations: { sells_only_legal_goods: true, no_counterfeit_or_stolen: true, information_is_true: true, will_honour_returns: true },
  };
  assert.deepEqual(missingBeforeSend(base, ok), []);
  assert.ok(missingBeforeSend({ ...base, residential_address: 'Plot 5' }, ok).includes('Your residential address'));
  assert.ok(missingBeforeSend({ ...base, returns_arrangements: '7 days' }, ok).includes('Your returns arrangements'));
  assert.ok(missingBeforeSend({ ...base, id_number: '1234' }, ok).length > 0);
});

test('User submits: nothing is missing once the form, documents and agreement are complete', () => {
  assert.deepEqual(missingBeforeSend(
    { ...emptyForm(), legal_name: 'Anna Mwansa', nationality: 'Zambian', is_adult: true, id_number: '123456/10/1', residential_address: 'Plot 5 Kabulonga Road',
      selling_location_id: 1, category_ids: [1], sourcing_type: 'import', sourcing_info: 'Bought from a supplier', experience_level: 'none',
      expected_catalogue_size: '10', returns_arrangements: 'Seven days returns', customer_service_arrangements: 'Replies daily on chat',
      declarations: { sells_only_legal_goods: true, no_counterfeit_or_stolen: true, information_is_true: true, will_honour_returns: true } },
    { agreementAccepted: true, documentKinds: requiredDocs('nrc'), contactVerified: true }), []);
});

test('Application is under review: shown, and not editable', () => {
  const v = buildSellerScreen(normalizeMine(answer({ application: app({ status: 'under_review' }) })));
  assert.equal(v.status, 'under_review');
  assert.equal(STATUS_LABEL.under_review, 'Under review');
  assert.equal(v.editable, false);
});

test('Additional information is requested: the open request is listed so the user can respond', () => {
  const v = buildSellerScreen(normalizeMine(answer({
    application: app({ status: 'additional_information_required' }),
    requests: [{ id: 'r1', message: 'Who supplies you?', document_kinds: [], status: 'open' }, { id: 'r0', message: 'old', status: 'answered' }],
  })));
  assert.equal(v.openRequests.length, 1);
  assert.equal(v.openRequests[0]?.id, 'r1');
  assert.equal(v.editable, false);
});

test('Seller gets approved: the dashboard opens, and the close option is offered', () => {
  const v = buildSellerScreen(normalizeMine(answer({ seller_status: 'active', application: app({ status: 'approved' }) })));
  assert.equal(v.mode, 'approved');
  assert.equal(v.close, SELLER_CLOSE);
  assert.equal(canUseSellingScreens({ status: 'active', hasBusiness: false }), true);
});

test('A seller from before applications existed (no application) is handled', () => {
  const v = buildSellerScreen(normalizeMine({ seller_status: 'active', application: null, documents: [], requests: [], history: [] }));
  assert.equal(v.mode, 'approved');
  assert.equal(v.close, SELLER_CLOSE);
});

test('Seller closes the account: permissions are gone, buyer features stay, and a new application can start', () => {
  const m = normalizeMine(answer({ seller_status: 'none', application: app({ status: 'closed' }) }));
  const v = buildSellerScreen(m);
  assert.equal(v.mode, 'application');
  assert.equal(v.close, null);
  assert.equal(v.editable, true, 'a closed application does not block applying again');
  assert.deepEqual(formFromApplication(m), emptyForm(), 'the new application starts empty');
  assert.equal(canUseSellingScreens({ status: 'none', hasBusiness: false }), false);
  assert.equal(showOrdersTab('none'), false);
});

test('A rejected applicant can start again from a blank form', () => {
  const m = normalizeMine(answer({ application: app({ status: 'rejected', legal_name: 'Old Name' }) }));
  assert.equal(buildSellerScreen(m).editable, true);
  assert.equal(formFromApplication(m).legal_name, '');
});

test('Suspended seller: no crash, and closing is offered with its own wording', () => {
  const v = buildSellerScreen(normalizeMine(answer({ seller_status: 'suspended', application: app({ status: 'suspended' }) })));
  assert.equal(v.close, SELLER_CLOSE_SUSPENDED);
  assert.equal(v.editable, false);
  assert.equal(canUseSellingScreens({ status: 'suspended', hasBusiness: false }), false);
});

test('Revoked seller: closing is offered once; afterwards the screen explains that selling stays off', () => {
  const before = buildSellerScreen(normalizeMine(answer({ seller_status: 'revoked', application: app({ status: 'revoked' }) })));
  assert.equal(before.close, SELLER_CLOSE_REVOKED);
  const after = buildSellerScreen(normalizeMine(answer({ seller_status: 'revoked', application: app({ status: 'revoked' }), history: [{ event: 'closed_by_seller' }] })));
  assert.equal(after.close, null);
  assert.match(after.closedNote ?? '', /stays switched off/);
});

test('every closing warning says it cannot be undone, mentions open orders, and keeps the buyer account', () => {
  for (const c of [SELLER_CLOSE, SELLER_CLOSE_SUSPENDED, SELLER_CLOSE_REVOKED]) {
    assert.match(c.intro, /cannot be undone/i);
    assert.ok(c.points.some((p) => /open orders/i.test(p)));
    assert.ok(c.points.some((p) => /buyer account|purchases/i.test(p)));
    assert.notEqual(c.confirm, c.button);
  }
});

test('Seller has unresolved orders: the readable reason from the database reaches the user unchanged', () => {
  const reason = 'You cannot close your selling account yet. Still open: 1 order request(s) waiting for your answer (accept or decline them); 1 disputed order(s) (these finish when support settles the dispute). Settle these first, then try again.';
  assert.equal(friendlyError({ message: reason, code: '23514' }), reason);
});

test('Seller RPC fails: the real error is logged and thrown, not turned into an empty answer', async () => {
  const logged: unknown[] = [];
  const failure = { message: 'boom', code: 'XX000' };
  await assert.rejects(loadMine(async () => ({ data: null, error: failure }), (m, d) => logged.push([m, d])), (e) => e === failure);
  assert.equal(logged.length, 1);
  await assert.rejects(loadMine(async () => { throw new Error('network down'); }, quiet), /network down/);
  await assert.rejects(loadMine(async () => ({ data: 'garbage', error: null }), quiet), MalformedResponseError);
  assert.match(friendlyError(new MalformedResponseError('x')), /Please try again/);
});

test('A missing database function shows a recoverable message', () => {
  assert.match(friendlyError({ code: 'PGRST202', message: 'Could not find the function public.seller_account_close(p_reason) in the schema cache' }), /being updated.*try again/i);
  assert.match(friendlyError({ message: 'new row for relation "seller_applications" violates check constraint "x"' }), /too short or too long/);
});

test('Account Hub: a failed seller request does not take the hub down and says so', async () => {
  const failed = await readSellerApplication(async () => ({ data: null, error: { message: 'permission denied for table seller_applications' } }), quiet);
  assert.equal(failed.status, null);
  assert.ok(failed.error && failed.error.length > 0, 'the error is reported, not hidden');
  const thrown = await readSellerApplication(async () => { throw new Error('offline'); }, quiet);
  assert.ok(thrown.error);
  const buyer = await readSellerApplication(async () => ({ data: OLD_BUYER_ANSWER, error: null }), quiet);
  assert.deepEqual(buyer, { status: null, error: null });
  const draft = await readSellerApplication(async () => ({ data: answer(), error: null }), quiet);
  assert.deepEqual(draft, { status: 'draft', error: null });
});
