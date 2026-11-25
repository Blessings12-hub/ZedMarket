import assert from 'node:assert/strict';
import test from 'node:test';

import { canResubmit, isFinished, MAX_FILE_ROWS, parseDelimited, parseImportText, TEMPLATE_CSV } from './bulkImport';

test('the template parses cleanly', () => {
  const r = parseImportText(TEMPLATE_CSV);
  assert.equal(r.ok, true);
  if (r.ok) {
    assert.equal(r.rows.length, 1);
    assert.equal(r.rows[0]!.sku, 'PH-001');
    assert.equal(r.rows[0]!.price_zmw, '150');
  }
});

test('quotes, commas, doubled quotes and line breaks inside quotes', () => {
  const t = parseDelimited('a,b\n"x, y","say ""hi"""\n"line1\nline2",z');
  assert.deepEqual(t, [['a', 'b'], ['x, y', 'say "hi"'], ['line1\nline2', 'z']]);
});

test('cells copied from Excel (tabs) and semicolons work, with a byte order mark', () => {
  const tab = 'SKU\tName\tPrice\tCategory\tCondition\tQty\nA1\tCase\t10\telectronics\tnew\t3';
  const r = parseImportText('﻿' + tab);
  assert.equal(r.ok, true);
  if (r.ok) assert.deepEqual(r.rows[0], { sku: 'A1', title: 'Case', price_zmw: '10', category: 'electronics', condition: 'new', quantity: '3' });
  assert.equal(parseImportText('sku;title;price;category;condition;stock\nA;B;1;c;new;2').ok, true);
});

test('missing required columns are named; unknown columns are reported and dropped', () => {
  const r = parseImportText('sku,title\nA,B');
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.message, /price_zmw.*category.*condition.*quantity/);
  const u = parseImportText('sku,title,price,category,condition,quantity,secret\nA,B,1,c,new,1,x');
  assert.equal(u.ok, true);
  if (u.ok) {
    assert.deepEqual(u.ignoredColumns, ['secret']);
    assert.equal('secret' in u.rows[0]!, false);
  }
});

test('empty input, header only and too many rows', () => {
  assert.equal(parseImportText('   \n').ok, false);
  assert.equal(parseImportText('sku,title,price,category,condition,quantity').ok, false);
  const big = 'sku,title,price,category,condition,quantity\n' + Array.from({ length: MAX_FILE_ROWS + 1 }, (_, i) => `S${i},T,1,c,new,1`).join('\n');
  assert.equal(parseImportText(big).ok, false);
});

test('resubmit and finished rules', () => {
  assert.equal(canResubmit('completed_with_errors', false), true);
  assert.equal(canResubmit('completed_with_errors', true), false);
  assert.equal(canResubmit('completed', false), false);
  assert.equal(isFinished('queued'), false);
  assert.equal(isFinished('failed'), true);
});
