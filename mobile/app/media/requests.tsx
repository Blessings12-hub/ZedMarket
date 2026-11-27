import { useState } from 'react';
import { Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { createRequest, fetchPermissions, listRequests, updateRequest } from '../../src/features/media/api';
import { PRIORITIES, REQUEST_KINDS, has, requestProblem } from '../../src/features/media/domain';
import { Card, MediaScreen, styles as s, when } from '../../src/features/media/ui';
import { useLoad } from '../../src/features/media/useLoad';
import { friendlyError } from '../../src/lib/errors';

// Any staff member can ask Media for something. Media staff with the requests permission also see and work the list.
export default function Requests() {
  const { userId } = useAuth();
  const perms = useLoad(fetchPermissions);
  const list = useLoad(listRequests);
  const [kind, setKind] = useState('graphic');
  const [title, setTitle] = useState('');
  const [details, setDetails] = useState('');
  const [priority, setPriority] = useState('normal');
  const [due, setDue] = useState('');
  const [note, setNote] = useState('');
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  const p = perms.data ?? [];
  const works = has(p, 'media.requests');

  async function send() {
    const problem = requestProblem(title, details);
    if (problem) return setErr(problem);
    if (due && !/^\d{4}-\d{2}-\d{2}$/.test(due)) return setErr('The due date looks like 2026-12-01.');
    setBusy(true); setErr(''); setMsg('');
    try { await createRequest(kind, title.trim(), details.trim(), priority, due || null); setTitle(''); setDetails(''); setDue(''); setMsg('Sent to the Media Department.'); await list.reload(); } catch (e) { setErr(friendlyError(e)); } finally { setBusy(false); }
  }
  async function move(id: string, status: string) {
    setBusy(true); setErr('');
    try { await updateRequest(id, status, status === 'in_progress' ? userId : null, note || undefined); setNote(''); await list.reload(); } catch (e) { setErr(friendlyError(e)); } finally { setBusy(false); }
  }

  return (
    <MediaScreen loading={list.loading} error={list.error || perms.error} onRetry={() => void list.reload()}>
      <Text style={s.title}>{works ? 'Requests' : 'Ask Media for something'}</Text>
      {err ? <Notice tone="error">{err}</Notice> : null}
      {msg ? <Notice>{msg}</Notice> : null}
      <SectionTitle>New request</SectionTitle>
      <View style={s.row}>{REQUEST_KINDS.map((k) => <Chip key={k.key} label={k.label} selected={kind === k.key} onPress={() => setKind(k.key)} />)}</View>
      <Field label="Title" value={title} onChangeText={setTitle} maxLength={120} required />
      <Field label="What do you need?" value={details} onChangeText={setDetails} multiline maxLength={2000} required />
      <View style={s.row}>{PRIORITIES.map((x) => <Chip key={x} label={x} selected={priority === x} onPress={() => setPriority(x)} />)}</View>
      <Field label="Needed by (optional, 2026-12-01)" value={due} onChangeText={setDue} />
      <Button title="Send request" loading={busy} onPress={() => void send()} />

      <SectionTitle>{works ? 'All requests' : 'Your requests'}</SectionTitle>
      {(list.data ?? []).map((r) => (
        <View key={r.id} style={{ gap: 6 }}>
          <Card title={r.title} note={r.details} meta={`${r.requesterName} (${r.fromDepartment}) · ${r.priority}${r.dueOn ? ` · by ${r.dueOn}` : ''} · ${when(r.createdAt)}${r.note ? ` · ${r.note}` : ''}`} right={r.status.replace('_', ' ')} />
          {works && (r.status === 'open' || r.status === 'in_progress') ? (
            <View style={s.row}>
              {r.status === 'open' ? <Button title="Take it" variant="secondary" onPress={() => void move(r.id, 'in_progress')} /> : null}
              <Button title="Mark done" variant="secondary" onPress={() => (note.trim().length >= 3 ? void move(r.id, 'done') : setErr('Write a short note for the person who asked in the box below first.'))} />
              <Button title="Decline" variant="secondary" onPress={() => (note.trim().length >= 3 ? void move(r.id, 'declined') : setErr('Write a reason in the box below first.'))} />
            </View>
          ) : null}
        </View>
      ))}
      {works ? <Field label="Reason or note (used when you decline or finish)" value={note} onChangeText={setNote} maxLength={500} /> : null}
      {list.data && list.data.length === 0 ? <Text style={s.muted}>No requests yet.</Text> : null}
    </MediaScreen>
  );
}
