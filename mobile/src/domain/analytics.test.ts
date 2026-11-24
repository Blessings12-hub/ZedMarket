import assert from 'node:assert/strict';
import test from 'node:test';

import { csvCell, hoursText, lusakaDate, minutesText, num, numOrNull, percentText, ratingText, toCsv } from './analytics';

test('missing numbers say so instead of showing zero', () => {
  assert.equal(percentText(null), 'No data yet');
  assert.equal(hoursText(undefined), 'No data yet');
  assert.equal(percentText(0), '0%');
});

test('percentages and times read plainly', () => {
  assert.equal(percentText(25), '25%');
  assert.equal(percentText(33.3), '33.3%');
  assert.equal(hoursText(0.5), '30 min');
  assert.equal(hoursText(4), '4 hours');
  assert.equal(hoursText(28), '28 hours');
  assert.equal(hoursText(72), '3 days');
  assert.equal(minutesText(30), '30 min');
  assert.equal(minutesText(90), '1.5 hours');
});

test('ratings say when there are none', () => {
  assert.equal(ratingText(null, 0), 'No reviews yet');
  assert.equal(ratingText(4.5, 2), '4.5 out of 5 (2 reviews)');
  assert.equal(ratingText(5, 1), '5.0 out of 5 (1 review)');
});

test('numbers from JSON may be text', () => {
  assert.equal(num('400.00'), 400);
  assert.equal(num(null), 0);
  assert.equal(num('abc'), 0);
  assert.equal(numOrNull(null), null);
  assert.equal(numOrNull('4.5'), 4.5);
});

test('dates count back in Zambia time', () => {
  // 23:30 UTC on 1 March is already 2 March in Lusaka
  assert.equal(lusakaDate(new Date('2026-03-01T23:30:00Z')), '2026-03-02');
  assert.equal(lusakaDate(new Date('2026-03-01T10:00:00Z'), 30), '2026-01-30');
});

test('csv cells are quoted and cannot run as formulas', () => {
  assert.equal(csvCell('plain'), 'plain');
  assert.equal(csvCell('a, b'), '"a, b"');
  assert.equal(csvCell('say "hi"'), '"say ""hi"""');
  assert.equal(csvCell('=SUM(A1:A9)'), "'=SUM(A1:A9)");
  assert.equal(csvCell('-5 off'), "'-5 off");
  assert.equal(csvCell(-5), '-5');
  assert.equal(csvCell(null), '');
});

test('csv has a header and one line per row', () => {
  assert.equal(toCsv(['Day', 'Total'], [['2026-03-01', 120], ['2026-03-02', 80]]), 'Day,Total\r\n2026-03-01,120\r\n2026-03-02,80\r\n');
});
