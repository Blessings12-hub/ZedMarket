import assert from 'node:assert/strict';
import test from 'node:test';

import {
  attachable, toggleId, PAUSABLE,
  contentActions, contentProblem, deleteConfirmed, extensionFor, formatBytes, groupByDay, mediaSections, queueGroups, requestProblem, scanLabel, uploadProblem,
  type CalendarRow, type QueueItem,
} from './domain';

const mediaStaff = ['media.access', 'media.upload', 'media.edit', 'media.archive', 'media.create', 'media.campaigns', 'media.performance', 'media.requests'];
const admin = ['media.access', 'media.review', 'media.publish', 'media.delete', 'media.performance', 'media.activity', 'media.requests'];

test('the dashboard shows only the sections the server says the person can open', () => {
  assert.deepEqual(mediaSections([]), []);
  assert.deepEqual(mediaSections(['media.performance']), [], 'a permission without access opens nothing');
  const m = mediaSections(mediaStaff).map((s) => s.key);
  assert.ok(m.includes('studio') && m.includes('library') && m.includes('performance') && m.includes('requests'));
  assert.ok(!m.includes('activity'));
  assert.ok(mediaSections(admin).map((s) => s.key).includes('activity'));
  assert.equal(mediaSections(['media.access']).map((s) => s.key).includes('performance'), false);
});

test('there are all eight dashboard areas from the brief, plus requests and activity', () => {
  const keys = mediaSections([...mediaStaff, 'media.activity']).map((s) => s.key);
  for (const k of ['studio', 'library', 'campaigns', 'announcements', 'queue', 'calendar', 'performance']) assert.ok(keys.includes(k), k);
});

test('a creator can edit and submit a draft but not approve or publish it', () => {
  assert.deepEqual(contentActions('draft', mediaStaff, true), ['edit', 'submit']);
  assert.deepEqual(contentActions('submitted', mediaStaff, true), []);
  assert.deepEqual(contentActions('approved', mediaStaff, true), []);
});

test('someone else cannot edit another person\'s draft', () => {
  assert.deepEqual(contentActions('draft', mediaStaff, false), []);
});

test('a reviewer decides on submitted work, never on their own', () => {
  assert.deepEqual(contentActions('submitted', admin, false), ['approve', 'changes', 'reject']);
  assert.deepEqual(contentActions('submitted', admin, true), []);
  assert.deepEqual(contentActions('draft', admin, false), []);
});

test('publishing needs the publish permission and approved content', () => {
  assert.deepEqual(contentActions('approved', admin, false), ['publish', 'schedule']);
  assert.deepEqual(contentActions('approved', mediaStaff, false), []);
  assert.deepEqual(contentActions('published', admin, false), ['withdraw']);
  assert.deepEqual(contentActions('scheduled', admin, false), ['publish', 'schedule', 'withdraw']);
  assert.deepEqual(contentActions('archived', admin, false), []);
});

test('a media person granted publishing sees publish on approved work, and edits stay with creators', () => {
  const granted = [...mediaStaff, 'media.publish'];
  assert.deepEqual(contentActions('approved', granted, true), ['publish', 'schedule']);
  assert.deepEqual(contentActions('rejected', granted, true), ['edit']);
  assert.deepEqual(contentActions('withdrawn', granted, true), ['edit']);
});

test('upload checks match the database', () => {
  assert.equal(uploadProblem({ mime: 'image/png', size: 5000 }), null);
  assert.equal(uploadProblem({ mime: 'video/mp4', size: 40 * 1024 * 1024 }), null);
  assert.match(uploadProblem({ mime: 'image/png', size: 11 * 1024 * 1024 }) ?? '', /10 MB/);
  assert.match(uploadProblem({ mime: 'video/mp4', size: 51 * 1024 * 1024 }) ?? '', /50 MB/);
  assert.match(uploadProblem({ mime: 'application/x-msdownload', size: 10 }) ?? '', /JPG, PNG/);
  assert.match(uploadProblem({ mime: null, size: 10 }) ?? '', /JPG, PNG/);
  assert.match(uploadProblem({ mime: 'image/png', size: 0 }) ?? '', /empty/);
  assert.equal(uploadProblem({ mime: 'image/jpeg', size: null }), null);
});

test('file extensions follow the type, never the picked name', () => {
  assert.equal(extensionFor('image/jpeg'), 'jpg');
  assert.equal(extensionFor('video/quicktime'), 'mov');
  assert.equal(extensionFor('text/html'), null);
});

test('sizes read well', () => {
  assert.equal(formatBytes(500), '500 B');
  assert.equal(formatBytes(2048), '2 KB');
  assert.equal(formatBytes(5 * 1024 * 1024), '5.0 MB');
  assert.equal(formatBytes(-1), '');
});

test('deleting needs the exact word', () => {
  assert.equal(deleteConfirmed('DELETE'), true);
  assert.equal(deleteConfirmed(' DELETE '), true);
  assert.equal(deleteConfirmed('delete'), false);
  assert.equal(deleteConfirmed(''), false);
});

test('scan wording is plain', () => {
  assert.equal(scanLabel('clean'), 'Safety check passed');
  assert.match(scanLabel('pending'), /Waiting/);
  assert.match(scanLabel('infected'), /Failed/);
});

test('the queue is split by what needs doing', () => {
  const item = (id: string, status: QueueItem['status']): QueueItem => ({ id, title: id, status, createdBy: 'x', scheduledFor: null });
  const g = queueGroups([item('a', 'submitted'), item('b', 'approved'), item('c', 'scheduled'), item('d', 'draft'), item('e', 'published')]);
  assert.deepEqual(g.review.map((i) => i.id), ['a']);
  assert.deepEqual(g.ready.map((i) => i.id), ['b']);
  assert.deepEqual(g.scheduled.map((i) => i.id), ['c']);
});

test('the calendar groups by Lusaka day, earliest first, and skips rows with no date', () => {
  const rows: CalendarRow[] = [
    { kind: 'content', id: '1', title: 'B', at: '2026-12-02T10:00:00Z', status: 'scheduled' },
    { kind: 'campaign', id: '2', title: 'A', at: '2026-12-01T08:00:00Z', status: 'active' },
    { kind: 'content', id: '3', title: 'C', at: '2026-12-02T12:00:00Z', status: 'scheduled' },
    { kind: 'content', id: '4', title: 'No date', at: null, status: 'scheduled' },
    { kind: 'content', id: '5', title: 'Bad date', at: 'nope', status: 'scheduled' },
  ];
  const g = groupByDay(rows);
  assert.deepEqual(g.map((d) => d.day), ['2026-12-01', '2026-12-02']);
  assert.deepEqual(g[1]?.rows.map((r) => r.id), ['1', '3']);
  // 23:30 UTC is already the next day in Lusaka (UTC+2)
  assert.equal(groupByDay([{ kind: 'content', id: 'x', title: 'Late', at: '2026-12-01T23:30:00Z', status: 'scheduled' }])[0]?.day, '2026-12-02');
});

test('request and content forms give friendly messages', () => {
  assert.match(requestProblem('Hi', 'Need a poster') ?? '', /short title/);
  assert.match(requestProblem('Poster', 'x') ?? '', /what you need/);
  assert.equal(requestProblem('Poster', 'Need a poster for launch'), null);
  assert.match(contentProblem('A', '') ?? '', /title/);
  assert.match(contentProblem('Title', 'x'.repeat(5001)) ?? '', /5000/);
  assert.equal(contentProblem('Title', ''), null);
});

test('only clean, active files can be attached, and at most ten', () => {
  const a = [
    { id: '1', status: 'active', scanStatus: 'clean' }, { id: '2', status: 'active', scanStatus: 'pending' },
    { id: '3', status: 'archived', scanStatus: 'clean' }, { id: '4', status: 'active', scanStatus: 'infected' },
  ];
  assert.deepEqual(attachable(a).map((x) => x.id), ['1']);
  assert.deepEqual(toggleId([], 'a'), ['a']);
  assert.deepEqual(toggleId(['a', 'b'], 'a'), ['b']);
  const many = Array.from({ length: 10 }, (_, i) => String(i));
  assert.equal(toggleId(many, 'x').length, 10);
});

test('only the three departments can be paused, never administrators or media', () => {
  assert.deepEqual(Object.keys(PAUSABLE).sort(), ['finance', 'moderator', 'support']);
  assert.ok(!('tech_admin' in PAUSABLE) && !('media' in PAUSABLE));
});
