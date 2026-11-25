import assert from 'node:assert/strict';
import test from 'node:test';

import { buildHub, businessSection, contextOptions, emailStatus, memberSince, passwordProblem, profileProblem, validContext, type HubBusiness, type HubFacts } from './hub';

const base: HubFacts = {
  isStaff: false, isSeller: false, sellerStatus: 'none', sellerApplication: null, paymentsOn: false, unreadNotifications: 0, unreadAlerts: 0, openRequestsToMe: 0, activeBuying: 0,
  listings: { live: 0, waiting: 0, total: 0 }, businesses: [], context: 'personal',
};
const biz = (role: HubBusiness['role'], verified = true): HubBusiness => ({ id: 'b1', name: 'Shop', slug: 'shop', role, verified });
const keys = (f: HubFacts) => buildHub(f).flatMap((s) => s.items.map((i) => i.key));

test('an ordinary buyer sees buying, an invitation to sell, help and settings, but no selling tools', () => {
  const k = keys(base);
  assert.ok(k.includes('orders') && k.includes('support') && k.includes('security'));
  assert.ok(!k.includes('my-products') && !k.includes('seller-dashboard') && !k.includes('post'));
  assert.ok(k.includes('become-seller') && k.includes('register-business'));
  assert.ok(!k.includes('staff-tools'));
  assert.ok(!k.includes('catalogue') && !k.includes('team'));
  assert.deepEqual(buildHub(base).map((s) => s.key), ['purchases', 'become-seller', 'communication', 'settings']);
});

test('a seller sees the selling tools and is no longer invited to apply', () => {
  const k = keys({ ...base, isSeller: true, sellerStatus: 'active', businesses: [biz('owner')] });
  assert.ok(k.includes('my-products') && k.includes('seller-dashboard') && k.includes('post'));
  assert.ok(!k.includes('become-seller') && !k.includes('register-business'));
  assert.deepEqual(buildHub({ ...base, isSeller: true, sellerStatus: 'active' }).map((s) => s.key), ['purchases', 'selling', 'become-seller', 'communication', 'settings']);
});

test('payments only appear when payments are switched on', () => {
  assert.ok(!keys(base).includes('payments'));
  assert.ok(keys({ ...base, paymentsOn: true }).includes('payments'));
});

test('staff tools only appear for staff, in their own section', () => {
  const sections = buildHub({ ...base, isStaff: true });
  assert.equal(sections[sections.length - 1]?.key, 'staff');
  assert.equal(sections.filter((s) => s.items.some((i) => i.key === 'staff-tools')).length, 1);
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
  const sections = buildHub({ ...base, isSeller: true, sellerStatus: 'active', unreadNotifications: 3, openRequestsToMe: 2, activeBuying: 1 });
  const badge = (key: string) => sections.flatMap((s) => s.items).find((i) => i.key === key)?.badge;
  assert.equal(badge('notifications'), '3 new');
  assert.equal(badge('selling-orders'), '2 to answer');
  assert.equal(badge('orders'), '1 open');
  assert.equal(badge('saved'), undefined);
});

test('product summary reflects the real counts', () => {
  const s = buildHub({ ...base, isSeller: true, sellerStatus: 'active', listings: { live: 2, waiting: 1, total: 4 } }).flatMap((x) => x.items).find((i) => i.key === 'my-products');
  assert.equal(s?.subtitle, '2 live, 1 waiting for review');
});

test('there is no deliveries or promotions item until those features exist', () => {
  const k = keys({ ...base, paymentsOn: true, businesses: [biz('owner')], context: 'b1' });
  assert.ok(!k.some((x) => /deliver|promo|bulk/i.test(x)));
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

test('saved addresses and coverage places are listed, and only the seller item is under selling', () => {
  const hub = buildHub({ ...base, isSeller: true, sellerStatus: 'active' });
  const where = (key: string) => hub.find((s) => s.items.some((i) => i.key === key))?.key;
  assert.equal(where('addresses'), 'settings');
  assert.equal(where('coverage-areas'), 'selling');
});

test('a suspended seller keeps their history but gets no selling tools', () => {
  const hub = buildHub({ ...base, sellerStatus: 'suspended' });
  const selling = hub.find((x) => x.key === 'selling');
  assert.ok(selling);
  const ks = selling.items.map((i) => i.key);
  assert.ok(ks.includes('seller-paused') && ks.includes('my-products'));
  assert.ok(!ks.includes('post') && !ks.includes('seller-dashboard'));
  assert.ok(!hub.flatMap((x) => x.items).some((i) => i.key === 'become-seller'), 'suspended sellers do not see the apply button');
});

test('an applicant sees their application state, never the selling tools', () => {
  const hub = buildHub({ ...base, sellerApplication: 'additional_information_required' });
  assert.ok(!hub.some((x) => x.key === 'selling'));
  const item = hub.flatMap((x) => x.items).find((i) => i.key === 'become-seller');
  assert.equal(item?.badge, 'Action needed');
  assert.equal(item?.href.pathname, '/verify/seller');
});
