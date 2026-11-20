import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  makeSlug,
  slugProblem,
  validateAppeal,
  validateBusinessName,
  validateDispute,
  validateRegistration,
  validateReview,
} from './trust';

test('shop names become safe web names', () => {
  assert.equal(makeSlug('Kabulonga Electronics'), 'kabulonga-electronics');
  assert.equal(makeSlug('  Café  & Sons!! '), 'cafe-sons');
  assert.equal(makeSlug('A'), 'a');
  assert.equal(slugProblem(makeSlug('Mama Chola')), null);
  assert.notEqual(slugProblem(makeSlug('A')), null);
  assert.notEqual(slugProblem(makeSlug('!!')), null);
});

test('long names keep a valid slug', () => {
  const slug = makeSlug('x'.repeat(30) + ' ' + 'y'.repeat(60));
  assert.ok(slug.length <= 60);
  assert.equal(slugProblem(slug), null);
});

test('business form checks', () => {
  assert.notEqual(validateBusinessName(' '), null);
  assert.equal(validateBusinessName('Mama Chola Fashion'), null);
  assert.notEqual(validateRegistration('12'), null);
  assert.equal(validateRegistration('120210012345'), null);
});

test('a review needs a rating but not a comment', () => {
  assert.notEqual(validateReview(null, ''), null);
  assert.equal(validateReview(4, ''), null);
  assert.notEqual(validateReview(4, 'x'.repeat(1001)), null);
});

test('dispute and appeal text limits match the database', () => {
  assert.notEqual(validateDispute('no', ''), null);
  assert.equal(validateDispute('Item not as described', ''), null);
  assert.notEqual(validateDispute('x'.repeat(201), ''), null);
  assert.notEqual(validateAppeal('too short'), null);
  assert.equal(validateAppeal('The photos show the real item, please look again.'), null);
});
