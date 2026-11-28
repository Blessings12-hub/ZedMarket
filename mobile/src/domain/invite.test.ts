import assert from 'node:assert/strict';
import test from 'node:test';

import { cleanInviteCode, inviteMessage, isInviteCode } from './invite';

test('codes are tidied before they are checked', () => {
  assert.equal(cleanInviteCode(' abcd-2345 '), 'ABCD2345');
  assert.equal(isInviteCode('abcd2345'), true);
  assert.equal(isInviteCode('ABCD 2345'), true);
});

test('look-alike characters and wrong lengths are refused', () => {
  assert.equal(isInviteCode('ABCD234'), false);
  assert.equal(isInviteCode('ABCD23456'), false);
  assert.equal(isInviteCode('ABCD0OI1'), false);
  assert.equal(isInviteCode(''), false);
});

test('the invite message carries the code, and a link only when there is one', () => {
  assert.match(inviteMessage('ABCD2345', null), /ABCD2345/);
  assert.equal(inviteMessage('ABCD2345', null).includes('http'), false);
  assert.match(inviteMessage('ABCD2345', 'https://zed.example'), /\nhttps:\/\/zed\.example$/);
});
