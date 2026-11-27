import { useState } from 'react';
import { Text } from 'react-native';

import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { fetchPermissions, listCampaigns, saveCampaign, type Campaign } from '../../src/features/media/api';
import { has } from '../../src/features/media/domain';
import { Card, MediaScreen, styles as s } from '../../src/features/media/ui';
import { useLoad } from '../../src/features/media/useLoad';
import { View } from 'react-native';
import { friendlyError } from '../../src/lib/errors';

const STATUSES = ['planned', 'active', 'finished', 'cancelled'];
const dateOk = (v: string) => v === '' || /^\d{4}-\d{2}-\d{2}$/.test(v);

export default function Campaigns() {
  const perms = useLoad(fetchPermissions);
  const list = useLoad(listCampaigns);
  const [editing, setEditing] = useState<Campaign | 'new' | null>(null);
  const [name, setName] = useState('');
  const [desc, setDesc] = useState('');
  const [starts, setStarts] = useState('');
  const [ends, setEnds] = useState('');
  const [status, setStatus] = useState('planned');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const p = perms.data ?? [];

  function open(c: Campaign | 'new') {
    setEditing(c); setErr('');
    const x = c === 'new' ? null : c;
    setName(x?.name ?? ''); setDesc(x?.description ?? ''); setStarts(x?.startsOn ?? ''); setEnds(x?.endsOn ?? ''); setStatus(x?.status ?? 'planned');
  }
  async function save() {
    if (name.trim().length < 2) return setErr('Give the campaign a name.');
    if (!dateOk(starts) || !dateOk(ends)) return setErr('Dates look like 2026-12-01.');
    setBusy(true); setErr('');
    try {
      await saveCampaign({ id: editing === 'new' || !editing ? null : editing.id, name: name.trim(), description: desc, startsOn: starts || null, endsOn: ends || null, status });
      setEditing(null); await list.reload();
    } catch (e) { setErr(friendlyError(e)); } finally { setBusy(false); }
  }

  return (
    <MediaScreen loading={list.loading} error={list.error || perms.error} onRetry={() => void list.reload()} denied={perms.data && !has(p, 'media.access') ? 'You do not have access to campaigns.' : undefined}>
      <Text style={s.title}>Campaign Manager</Text>
      {err ? <Notice tone="error">{err}</Notice> : null}
      {editing ? (
        <>
          <Field label="Name" value={name} onChangeText={setName} maxLength={120} required />
          <Field label="Description" value={desc} onChangeText={setDesc} multiline maxLength={1000} />
          <Field label="Starts (2026-12-01)" value={starts} onChangeText={setStarts} />
          <Field label="Ends (2026-12-31)" value={ends} onChangeText={setEnds} />
          <SectionTitle>Status</SectionTitle>
          <View style={s.row}>{STATUSES.map((x) => <Chip key={x} label={x} selected={status === x} onPress={() => setStatus(x)} />)}</View>
          <Button title="Save campaign" loading={busy} onPress={() => void save()} />
          <Button title="Cancel" variant="secondary" onPress={() => setEditing(null)} />
        </>
      ) : (
        <>
          {has(p, 'media.campaigns') ? <Button title="New campaign" onPress={() => open('new')} /> : null}
          {(list.data ?? []).map((c) => (
            <Card key={c.id} title={c.name} note={c.description ?? undefined} meta={[c.startsOn, c.endsOn].filter(Boolean).join(' to ')} right={c.status} onPress={has(p, 'media.campaigns') ? () => open(c) : undefined} />
          ))}
          {list.data && list.data.length === 0 ? <Text style={s.muted}>No campaigns yet.</Text> : null}
        </>
      )}
    </MediaScreen>
  );
}
