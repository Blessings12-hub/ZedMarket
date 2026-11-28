import assert from 'node:assert/strict';
import test from 'node:test';

import { LEGAL_DRAFT_NOTE, PRIVACY, TERMS, TERMS_VERSION } from './legal';

test('the legal text is marked as a draft until a lawyer has checked it', () => {
  assert.match(LEGAL_DRAFT_NOTE, /not been checked by a lawyer/i);
  assert.match(TERMS_VERSION, /^\d{4}-\d+$/);
});

test('both documents have sections and every section has points', () => {
  for (const doc of [TERMS, PRIVACY]) {
    assert.ok(doc.length >= 4);
    for (const s of doc) assert.ok(s.title && s.points.length > 0, s.title);
  }
});

test('the privacy text says what deleting an account does', () => {
  const text = PRIVACY.flatMap((s) => s.points).join(' ');
  assert.match(text, /Deleted user/);
  assert.match(text, /crashes/);
});
