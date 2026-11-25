import assert from 'node:assert/strict';
import test from 'node:test';

import { canShareSellerProfile, canUseSellingScreens, gateMessage, NO_ACCESS, showOrdersTab, showSellingOrders, toSellerStatus } from './sellerAccess';

test('an ordinary buyer gets no selling tools anywhere', () => {
  assert.equal(showOrdersTab('none'), false);
  assert.equal(canUseSellingScreens(NO_ACCESS), false);
  assert.equal(canShareSellerProfile('none'), false);
  assert.equal(showSellingOrders('none', false), false);
});

test('only an approved seller gets the Orders tab and Share profile', () => {
  assert.equal(showOrdersTab('active'), true);
  assert.equal(canShareSellerProfile('active'), true);
  for (const s of ['none', 'suspended', 'revoked'] as const) {
    assert.equal(showOrdersTab(s), false, s);
    assert.equal(canShareSellerProfile(s), false, s);
  }
});

test('applicants, suspended and revoked sellers cannot open the selling screens', () => {
  for (const s of ['none', 'suspended', 'revoked'] as const) assert.equal(canUseSellingScreens({ status: s, hasBusiness: false }), false, s);
  assert.equal(canUseSellingScreens({ status: 'active', hasBusiness: false }), true);
});

test('business members can open the selling screens, because the database checks the business', () => {
  assert.equal(canUseSellingScreens({ status: 'none', hasBusiness: true }), true);
});

test('the Selling filter shows for people who sell or used to, or who still have selling orders', () => {
  assert.equal(showSellingOrders('active', false), true);
  assert.equal(showSellingOrders('suspended', false), true);
  assert.equal(showSellingOrders('revoked', false), true);
  assert.equal(showSellingOrders('none', true), true);
});

test('unknown or missing statuses count as not a seller', () => {
  assert.equal(toSellerStatus(undefined), 'none');
  assert.equal(toSellerStatus(null), 'none');
  assert.equal(toSellerStatus('pending'), 'none');
  assert.equal(toSellerStatus('active'), 'active');
  assert.equal(toSellerStatus('suspended'), 'suspended');
});

test('the gate invites buyers to apply and explains a paused account', () => {
  assert.equal(gateMessage('none').action, 'Become a seller');
  assert.match(gateMessage('none').body, /verify/i);
  assert.equal(gateMessage('suspended').title, 'Selling is switched off');
  assert.equal(gateMessage('revoked').title, 'Selling has been revoked');
  assert.equal(gateMessage('revoked').action, 'See what happened');
});
