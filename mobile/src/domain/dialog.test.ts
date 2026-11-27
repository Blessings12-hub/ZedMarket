import assert from 'node:assert/strict';
import test from 'node:test';

import { runWebDialog, type DialogButton } from './dialog';

function run(buttons: DialogButton[] | undefined, answers: boolean[]) {
  const asked: string[] = [];
  const told: string[] = [];
  let i = 0;
  runWebDialog('Delete this address?', 'Home', buttons, (t) => { asked.push(t); return answers[i++] ?? false; }, (t) => told.push(t));
  return { asked, told };
}

test('a question runs its action only when the person agrees', () => {
  const log: string[] = [];
  const buttons: DialogButton[] = [
    { text: 'Keep it', style: 'cancel', onPress: () => { log.push('kept'); } },
    { text: 'Delete', style: 'destructive', onPress: () => { log.push('deleted'); } },
  ];
  run(buttons, [true]);
  assert.deepEqual(log, ['deleted']);
  log.length = 0;
  run(buttons, [false]);
  assert.deepEqual(log, ['kept']);
});

test('the question names what OK and Cancel do, so the browser box is clear', () => {
  const { asked } = run([{ text: 'Go back', style: 'cancel' }, { text: 'Yes', onPress: () => undefined }], [false]);
  assert.equal(asked.length, 1);
  assert.match(asked[0]!, /Delete this address\?/);
  assert.match(asked[0]!, /OK: Yes/);
  assert.match(asked[0]!, /Cancel: Go back/);
});

test('a plain message is shown, not asked, and its single button still runs', () => {
  const log: string[] = [];
  const { asked, told } = run([{ text: 'OK', onPress: () => { log.push('ok'); } }], []);
  assert.equal(asked.length, 0);
  assert.equal(told.length, 1);
  assert.deepEqual(log, ['ok']);
  assert.equal(run(undefined, []).told.length, 1);
});

test('with several actions the first one the person agrees to runs, and nothing runs if they refuse all', () => {
  const log: string[] = [];
  const buttons: DialogButton[] = [
    { text: 'Not now', style: 'cancel', onPress: () => { log.push('cancel'); } },
    { text: 'Sign in', onPress: () => { log.push('sign in'); } },
    { text: 'Create account', onPress: () => { log.push('create'); } },
  ];
  run(buttons, [false, true]);
  assert.deepEqual(log, ['create']);
  log.length = 0;
  run(buttons, [false, false]);
  assert.deepEqual(log, ['cancel']);
});
