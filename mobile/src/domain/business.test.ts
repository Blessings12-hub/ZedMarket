import assert from 'node:assert/strict';
import test from 'node:test';

import { emailProblem, parseQuantity, permissionString, phoneProblem, roleCan, stockChange, stockLabel } from './business';

// These strings are the same ones supabase/tests/business_hub.sql checks against the database.
test('the permission table matches the database', () => {
  assert.equal(permissionString('owner'), 'ttttttttt');
  assert.equal(permissionString('manager'), 'tfttttttt');
  assert.equal(permissionString('staff'), 'tfffftttf');
  assert.equal(permissionString(null), 'fffffffff');
});

test('only the owner manages the team, and staff cannot see analytics', () => {
  assert.equal(roleCan('manager', 'manage_team'), false);
  assert.equal(roleCan('owner', 'manage_team'), true);
  assert.equal(roleCan('staff', 'view_analytics'), false);
  assert.equal(roleCan('staff', 'manage_inventory'), true);
});

test('email and phone checks', () => {
  assert.equal(emailProblem('a@b.co'), null);
  assert.notEqual(emailProblem('a@b'), null);
  assert.notEqual(emailProblem('no spaces@x.com'), null);
  assert.equal(phoneProblem(''), null);
  assert.equal(phoneProblem('+260 971 234 567'), null);
  assert.notEqual(phoneProblem('call me'), null);
});

test('stock numbers', () => {
  assert.equal(parseQuantity(' 12 '), 12);
  assert.equal(parseQuantity('1.5'), null);
  assert.equal(parseQuantity('abc'), null);
  assert.equal(parseQuantity('1234567'), null);
  assert.equal(stockLabel(null, null), 'Stock not tracked');
  assert.equal(stockLabel(0, 2), 'Out of stock');
  assert.equal(stockLabel(2, 2), 'Low: 2 left');
  assert.equal(stockLabel(9, 2), '9 in stock');
});

test('stock changes get the right sign for the reason', () => {
  assert.deepEqual(stockChange('restock', '4'), { change: 4 });
  assert.deepEqual(stockChange('damaged', '2'), { change: -2 });
  assert.deepEqual(stockChange('correction', '-3'), { change: -3 });
  assert.ok('problem' in stockChange('restock', '-4'));
  assert.ok('problem' in stockChange('damaged', '0'));
  assert.ok('problem' in stockChange('return', 'x'));
});
