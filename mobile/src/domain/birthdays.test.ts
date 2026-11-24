import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  MAX_WISH,
  birthdayProblem,
  boardNote,
  daysInMonth,
  daysUntilLabel,
  formatBirthday,
  initials,
  wishProblem,
  wishesLeft,
} from './birthdays';

test('month lengths allow 29 February but nothing longer', () => {
  assert.equal(daysInMonth(2), 29);
  assert.equal(daysInMonth(4), 30);
  assert.equal(daysInMonth(12), 31);
});

test('only real days are accepted', () => {
  assert.equal(birthdayProblem(3, 5), null);
  assert.equal(birthdayProblem(2, 29), null);
  assert.notEqual(birthdayProblem(2, 30), null);
  assert.notEqual(birthdayProblem(4, 31), null);
  assert.notEqual(birthdayProblem(13, 1), null);
  assert.notEqual(birthdayProblem(0, 1), null);
  assert.notEqual(birthdayProblem(null, 5), null);
  assert.notEqual(birthdayProblem(5, null), null);
  assert.notEqual(birthdayProblem(5, 0), null);
  assert.notEqual(birthdayProblem(5, 1.5), null);
});

test('a birthday is shown as day and month, never with a year', () => {
  assert.equal(formatBirthday(3, 5), '5 March');
  assert.equal(formatBirthday(12, 25), '25 December');
  assert.equal(formatBirthday(13, 1), '');
  for (let m = 1; m <= 12; m++) assert.doesNotMatch(formatBirthday(m, 1), /\d{4}/);
});

test('days until reads naturally', () => {
  assert.equal(daysUntilLabel(0), 'Today');
  assert.equal(daysUntilLabel(1), 'Tomorrow');
  assert.equal(daysUntilLabel(10), 'In 10 days');
});

test('wishes are checked before sending', () => {
  assert.notEqual(wishProblem('   '), null);
  assert.equal(wishProblem('Happy birthday!'), null);
  assert.notEqual(wishProblem('x'.repeat(MAX_WISH + 1)), null);
  assert.equal(wishProblem('x'.repeat(MAX_WISH)), null);
});

test('wishes left never goes below zero', () => {
  assert.equal(wishesLeft(1, 3), 2);
  assert.equal(wishesLeft(5, 3), 0);
});

test('initials for the photo placeholder', () => {
  assert.equal(initials('Mwila Banda'), 'MB');
  assert.equal(initials('Thandi'), 'T');
  assert.equal(initials('  '), '?');
  assert.equal(initials('Anna Maria Lungu'), 'AL');
});

test('the board explains why you can or cannot write', () => {
  assert.match(boardNote({ isMe: true, canWrite: false, written: 0, max: 3 }), /your board/);
  assert.match(boardNote({ isMe: false, canWrite: true, written: 1, max: 3 }), /2 more wishes/);
  assert.match(boardNote({ isMe: false, canWrite: true, written: 2, max: 3 }), /1 more wish\./);
  assert.match(boardNote({ isMe: false, canWrite: false, written: 3, max: 3 }), /most wishes/);
  assert.match(boardNote({ isMe: false, canWrite: false, written: 0, max: 3 }), /closed/);
});
