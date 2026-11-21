import assert from 'node:assert/strict';
import { test } from 'node:test';

import { listingLink, listingShareMessage, sellerLink, sellerShareMessage, webBase } from './share';

const ID = '3f2b8c1e-5d4a-4b6f-9a7e-1c2d3e4f5a6b';

test('web address is used only when it is a real http(s) address', () => {
  assert.equal(webBase('https://zedmarket.example/'), 'https://zedmarket.example');
  assert.equal(webBase('  https://zedmarket.example//  '), 'https://zedmarket.example');
  assert.equal(webBase(''), null);
  assert.equal(webBase(undefined), null);
  assert.equal(webBase('zedmarket.example'), null);
  assert.equal(webBase('javascript:alert(1)'), null);
});

test('links are built only from a configured address and a real id', () => {
  const base = 'https://zedmarket.example';
  assert.equal(listingLink(base, ID), `${base}/listing/${ID}`);
  assert.equal(sellerLink(base, ID), `${base}/seller/${ID}`);
  assert.equal(listingLink(null, ID), null);
  assert.equal(listingLink(base, 'not-an-id'), null);
  assert.equal(sellerLink(base, '../../admin'), null);
});

test('share text carries the price in kwacha and a link only when there is one', () => {
  const withLink = listingShareMessage({ title: 'Samsung phone', price: 500, link: 'https://zedmarket.example/listing/x' });
  assert.match(withLink, /^Samsung phone for K ?500/);
  assert.match(withLink, /\nhttps:\/\/zedmarket\.example\/listing\/x$/);
  const noLink = listingShareMessage({ title: 'Samsung phone', price: 500, link: null });
  assert.equal(noLink.includes('http'), false);
  assert.equal(sellerShareMessage({ name: 'Mwila', link: null }), 'Mwila on ZedMarket');
});
