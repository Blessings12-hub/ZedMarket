import assert from 'node:assert/strict';
import test from 'node:test';

import { badgeText, orderStrip, profileNudge, quickTiles, sellingBanner, STRIP_STEPS, type StripOrder } from './dashboard';

const order = (over: Partial<StripOrder> = {}): StripOrder => ({ id: 'o1', title: 'Phone', status: 'requested', cancelKind: null, handedOverAt: null, fulfilment: 'collection', ...over });

test('badges are hidden at zero, exact up to nine, and 9+ beyond', () => {
  assert.equal(badgeText(0), undefined);
  assert.equal(badgeText(-2), undefined);
  assert.equal(badgeText(Number.NaN), undefined);
  assert.equal(badgeText(3), '3');
  assert.equal(badgeText(9), '9');
  assert.equal(badgeText(10), '9+');
});

test('the hub always has the same six buyer tiles, and no selling tile or seller count', () => {
  const t = quickTiles({ activeBuying: 2, unreadAlerts: 4 });
  assert.deepEqual(t.map((x) => x.key), ['orders', 'saved', 'messages', 'alerts', 'reviews', 'support']);
  assert.equal(t.find((x) => x.key === 'orders')?.count, 2);
  assert.equal(t.find((x) => x.key === 'alerts')?.count, 4);
  assert.ok(!t.some((x) => x.key === 'listings'));
});

test('Orders opens a screen with a back arrow, not the hidden Orders tab', () => {
  assert.equal(quickTiles({ activeBuying: 0, unreadAlerts: 0 }).find((x) => x.key === 'orders')?.href.pathname, '/purchases');
});

test('the strip lists open purchases and skips finished, cancelled, declined and expired ones', () => {
  const { items } = orderStrip([
    order({ id: 'a', status: 'requested' }),
    order({ id: 'b', status: 'completed' }),
    order({ id: 'c', status: 'cancelled', cancelKind: 'cancelled' }),
    order({ id: 'd', status: 'cancelled', cancelKind: 'declined' }),
    order({ id: 'e', status: 'cancelled', cancelKind: 'expired' }),
    order({ id: 'f', status: 'confirmed' }),
  ]);
  assert.deepEqual(items.map((i) => i.id), ['a', 'f']);
});

test('steps follow the order: requested, confirmed, handed over', () => {
  const steps = (o: StripOrder) => orderStrip([o]).items[0]?.step;
  assert.equal(steps(order()), 0);
  assert.equal(steps(order({ status: 'confirmed' })), 1);
  assert.equal(steps(order({ status: 'confirmed', handedOverAt: '2026-11-20T10:00:00Z' })), 2);
  assert.equal(STRIP_STEPS.length, 4);
});

test('an order waiting for the buyer to confirm comes first and says so', () => {
  const { items } = orderStrip([order({ id: 'a' }), order({ id: 'h', status: 'confirmed', handedOverAt: '2026-11-20T10:00:00Z' })]);
  assert.equal(items[0]?.id, 'h');
  assert.equal(items[0]?.needsYou, true);
  assert.match(items[0]?.label ?? '', /confirm you have it/i);
  assert.equal(items[1]?.needsYou, false);
});

test('a disputed order is shown as a problem, not as progress', () => {
  const i = orderStrip([order({ status: 'disputed' })]).items[0];
  assert.equal(i?.problem, true);
  assert.equal(i?.label, 'In dispute');
});

test('the strip is capped and says how many more there are; empty stays empty', () => {
  const many = Array.from({ length: 8 }, (_, n) => order({ id: `o${n}` }));
  const r = orderStrip(many, 5);
  assert.equal(r.items.length, 5);
  assert.equal(r.more, 3);
  assert.deepEqual(orderStrip([]), { items: [], more: 0 });
});

test('the nudge asks for the email first, then the profile, then nothing', () => {
  assert.equal(profileNudge({ emailConfirmed: false, hasAvatar: false, hasBio: false })?.key, 'email');
  assert.equal(profileNudge({ emailConfirmed: true, hasAvatar: false, hasBio: true })?.key, 'profile');
  assert.equal(profileNudge({ emailConfirmed: true, hasAvatar: true, hasBio: false })?.key, 'profile');
  assert.equal(profileNudge({ emailConfirmed: true, hasAvatar: true, hasBio: true }), null);
});

test('a buyer is invited to sell, never pushed: it says buying comes first and the team verifies', () => {
  const b = sellingBanner({ sellerStatus: 'none', sellerApplication: null, businesses: [] });
  assert.equal(b?.cta, 'Become a seller');
  assert.match(b?.body ?? '', /buy first/i);
  assert.match(b?.body ?? '', /verify/i);
  assert.equal(b?.href.pathname, '/verify/seller');
  assert.equal(b?.secondary?.title, 'Register a business');
});

test('the banner follows the application and hides the business link when there is already one', () => {
  const draft = sellingBanner({ sellerStatus: 'none', sellerApplication: 'draft', businesses: [{ id: 'b', name: 'S', slug: 's', role: 'owner', verified: true }] });
  assert.equal(draft?.cta, 'Continue your application');
  assert.equal(draft?.badge, 'Draft');
  assert.equal(draft?.secondary, undefined);
  assert.equal(sellingBanner({ sellerStatus: 'none', sellerApplication: 'additional_information_required', businesses: [] })?.badge, 'Action needed');
  // a closed application starts fresh
  assert.equal(sellingBanner({ sellerStatus: 'none', sellerApplication: 'closed', businesses: [] })?.cta, 'Become a seller');
});

test('sellers of every kind get no invitation', () => {
  for (const s of ['active', 'suspended', 'revoked'] as const) assert.equal(sellingBanner({ sellerStatus: s, sellerApplication: 'approved', businesses: [] }), null, s);
});
