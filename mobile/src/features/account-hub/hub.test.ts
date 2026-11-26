import assert from 'node:assert/strict';
import test from 'node:test';

import { buildHub, buildSellCentre, businessSection, contextOptions, emailStatus, memberSince, passwordProblem, profileProblem, validContext, type HubBusiness, type HubFacts } from './hub';

const base: HubFacts = {
  isStaff: false, isSeller: false, sellerStatus: 'none', sellerApplication: null, paymentsOn: false, unreadNotifications: 0, unreadAlerts: 0, openRequestsToMe: 0, activeBuying: 0,
  listings: { live: 0, waiting: 0, total: 0 }, businesses: [], context: 'personal',
};
const biz = (role: HubBusiness['role'], verified = true): HubBusiness => ({ id: 'b1', name: 'Shop', slug: 'shop', role, verified });
const keys = (f: HubFacts) => buildHub(f).flatMap((s) => s.items.map((i) => i.key));

const allKeys = (f: HubFacts) => buildHub(f).flatMap((s) => s.items.map((i) => i.key));
const sellKeys = (f: HubFacts) => buildSellCentre(f).flatMap((s) => s.items.map((i) => i.key));

test('the hub list repeats nothing the quick tiles already open', () => {
  const tileKeys = ['orders', 'saved', 'messages', 'alerts', 'reviews', 'support'];
  for (const f of [base, { ...base, isSeller: true, sellerStatus: 'active' as const, paymentsOn: true }, { ...base, isStaff: true }]) {
    for (const k of allKeys(f)) assert.ok(!tileKeys.includes(k), `${k} is already a tile`);
  }
});

test('no row appears twice on the hub, and no two rows open the same place', () => {
  const items = buildHub({ ...base, isStaff: true, paymentsOn: true, sellerStatus: 'active', isSeller: true }).flatMap((s) => s.items);
  assert.equal(new Set(items.map((i) => i.key)).size, items.length);
  const paths = items.map((i) => i.href.pathname);
  assert.equal(new Set(paths).size, paths.length, paths.join(', '));
});

test('the hub has no seller or business tools, only one door to the selling area', () => {
  const all = [base, { ...base, isSeller: true, sellerStatus: 'active' as const, businesses: [biz('owner')], context: 'b1' }, { ...base, sellerStatus: 'suspended' as const }];
  for (const f of all) {
    const items = buildHub(f).flatMap((s) => s.items);
    const sell = items.filter((i) => i.href.pathname === '/sell-hub');
    assert.equal(sell.length, 1);
    const banned = /sell|analytics|delivery|account\/listings|business|verify/;
    assert.ok(!items.some((i) => i.key !== 'sell-centre' && banned.test(i.href.pathname)), items.map((i) => i.href.pathname).join(', '));
  }
});

test('the hub order is activity, settings, selling door, then staff last', () => {
  assert.deepEqual(buildHub(base).map((s) => s.key), ['activity', 'settings', 'sell']);
  assert.deepEqual(buildHub({ ...base, isStaff: true }).map((s) => s.key), ['activity', 'settings', 'sell', 'staff']);
});

test('payments only appear when payments are switched on', () => {
  assert.ok(!allKeys(base).includes('payments'));
  assert.ok(allKeys({ ...base, paymentsOn: true }).includes('payments'));
});

test('staff tools only appear for staff', () => {
  assert.ok(!allKeys(base).includes('staff-tools'));
  assert.ok(allKeys({ ...base, isStaff: true }).includes('staff-tools'));
});

test('the selling door says what is true for each person', () => {
  const entry = (f: HubFacts) => buildHub(f).flatMap((s) => s.items).find((i) => i.key === 'sell-centre')!;
  assert.equal(entry(base).title, 'Sell on ZedMarket');
  assert.equal(entry({ ...base, sellerApplication: 'additional_information_required' }).badge, 'Action needed');
  const active = entry({ ...base, isSeller: true, sellerStatus: 'active', openRequestsToMe: 2, listings: { live: 2, waiting: 1, total: 3 } });
  assert.equal(active.title, 'Selling and business');
  assert.equal(active.subtitle, '2 live, 1 waiting for review');
  assert.equal(active.badge, '2 to answer');
  assert.equal(entry({ ...base, sellerStatus: 'revoked' }).badge, 'revoked');
});

test('a buyer who opens the selling area sees the invitation and no selling tools', () => {
  const k = sellKeys(base);
  assert.deepEqual(k, ['become-seller', 'register-business']);
  assert.match(buildSellCentre(base)[0]?.note ?? '', /verify/i);
  assert.ok(!k.includes('my-products') && !k.includes('post') && !k.includes('seller-dashboard'));
});

test('an approved seller sees tools and business registration, and is not invited to apply', () => {
  const sections = buildSellCentre({ ...base, isSeller: true, sellerStatus: 'active' });
  assert.deepEqual(sections.map((s) => s.key), ['selling', 'become-seller']);
  const k = sellKeys({ ...base, isSeller: true, sellerStatus: 'active' });
  assert.ok(k.includes('my-products') && k.includes('seller-dashboard') && k.includes('post') && k.includes('coverage-areas'));
  assert.ok(!k.includes('become-seller'));
  assert.equal(sections[1]?.note, undefined);
});

test('a suspended seller keeps history but gets no selling tools and no apply button', () => {
  const k = sellKeys({ ...base, sellerStatus: 'suspended' });
  assert.ok(k.includes('seller-paused') && k.includes('my-products'));
  assert.ok(!k.includes('post') && !k.includes('seller-dashboard') && !k.includes('become-seller'));
});

test('an applicant sees their application state in the selling area', () => {
  const item = buildSellCentre({ ...base, sellerApplication: 'rejected' }).flatMap((s) => s.items).find((i) => i.key === 'become-seller');
  assert.equal(item?.badge, 'Not approved');
  assert.equal(item?.href.pathname, '/verify/seller');
  const closed = buildSellCentre({ ...base, sellerApplication: 'closed' }).flatMap((s) => s.items).find((i) => i.key === 'become-seller');
  assert.equal(closed?.badge, 'Application required');
});

test('business sections come after selling and follow the switcher', () => {
  const f = { ...base, isSeller: true, sellerStatus: 'active' as const, businesses: [biz('owner')], context: 'b1' };
  assert.deepEqual(buildSellCentre(f).map((s) => s.key), ['selling', 'business']);
});

test('orders from the selling area open the screen that has a back arrow', () => {
  const orders = buildSellCentre({ ...base, isSeller: true, sellerStatus: 'active' }).flatMap((s) => s.items).find((i) => i.key === 'selling-orders');
  assert.equal(orders?.href.pathname, '/purchases');
});

test('the personal settings keep delivery addresses', () => {
  assert.equal(buildHub(base).find((s) => s.items.some((i) => i.key === 'addresses'))?.key, 'settings');
});

test('no business tools in personal view, even for a business owner', () => {
  assert.equal(businessSection({ ...base, businesses: [biz('owner')] }), null);
});

test('business tools follow the role', () => {
  const k = (role: HubBusiness['role']) => businessSection({ ...base, businesses: [biz(role)], context: 'b1' })!.items.map((i) => i.key);
  assert.ok(k('owner').includes('biz-analytics') && k('owner').includes('catalogue') && k('owner').includes('branches'));
  assert.ok(k('manager').includes('biz-analytics') && k('manager').includes('catalogue'));
  const staff = k('staff');
  assert.ok(staff.includes('inventory') && staff.includes('biz-orders') && staff.includes('team'));
  assert.ok(!staff.includes('biz-analytics') && !staff.includes('catalogue') && !staff.includes('branches'));
});

test('only the owner of an unverified business is told to verify it', () => {
  const has = (role: HubBusiness['role'], verified: boolean) =>
    businessSection({ ...base, businesses: [biz(role, verified)], context: 'b1' })!.items.some((i) => i.key === 'biz-verify');
  assert.equal(has('owner', false), true);
  assert.equal(has('owner', true), false);
  assert.equal(has('manager', false), false);
});

test('a business id the person does not belong to shows nothing', () => {
  assert.equal(businessSection({ ...base, businesses: [biz('owner')], context: 'someone-elses' }), null);
  assert.equal(validContext('someone-elses', [biz('owner')]), 'personal');
  assert.equal(validContext('b1', [biz('owner')]), 'b1');
});

test('the switcher lists personal first, then each business', () => {
  assert.deepEqual(contextOptions([biz('owner')]).map((o) => o.key), ['personal', 'b1']);
});

test('badges show real counts and stay hidden at zero', () => {
  const items = buildHub({ ...base, unreadNotifications: 3 }).flatMap((s) => s.items);
  assert.equal(items.find((i) => i.key === 'notifications')?.badge, '3 new');
  assert.equal(buildHub(base).flatMap((s) => s.items).find((i) => i.key === 'notifications')?.badge, undefined);
});

test('product summary reflects the real counts', () => {
  const s = buildSellCentre({ ...base, isSeller: true, sellerStatus: 'active', listings: { live: 2, waiting: 1, total: 4 } }).flatMap((x) => x.items).find((i) => i.key === 'my-products');
  assert.equal(s?.subtitle, '2 live, 1 waiting for review');
});

test('small helpers', () => {
  assert.equal(emailStatus(null), 'unverified');
  assert.equal(emailStatus('2026-01-01'), 'verified');
  assert.equal(memberSince('2026-11-05T10:00:00Z'), 'November 2026');
  assert.equal(memberSince(null), '');
  assert.equal(profileProblem('A', ''), 'Your name must be between 2 and 60 characters.');
  assert.equal(profileProblem('Ann', 'x'.repeat(501)), 'About you must be 500 characters or fewer.');
  assert.equal(profileProblem('Ann', ''), null);
  assert.equal(passwordProblem('short', 'short'), 'Use at least 8 characters.');
  assert.equal(passwordProblem('longenough', 'different1'), 'The two passwords do not match.');
  assert.equal(passwordProblem('longenough', 'longenough'), null);
});

