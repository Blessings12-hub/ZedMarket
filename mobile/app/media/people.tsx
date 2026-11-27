import { useState } from 'react';
import { Text, View } from 'react-native';

import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { canManageTeam } from '../../src/domain/admin';
import { fetchMyRoles, findPeople, grantRole, revokeRole } from '../../src/features/admin/api';
import { grantPermission, listMediaPeople, listPermissionCatalogue, resetPermission, revokePermission, setMediaTitle, type MediaPerson } from '../../src/features/media/api';
import { TITLE_LABEL } from '../../src/features/media/domain';
import { Card, MediaScreen, styles as s } from '../../src/features/media/ui';
import { useLoad } from '../../src/features/media/useLoad';
import { useAuth } from '../../src/auth/AuthProvider';
import { friendlyError } from '../../src/lib/errors';

// Administrators only: appoint and remove Media staff, set their department role, and grant or take away single permissions.
export default function MediaPeople() {
  const { userId } = useAuth();
  const roles = useLoad(async () => (userId ? fetchMyRoles(userId) : []), [userId]);
  const allowed = canManageTeam(roles.data ?? []);
  const people = useLoad(async () => (allowed ? listMediaPeople() : []), [allowed]);
  const catalogue = useLoad(async () => (allowed ? listPermissionCatalogue() : []), [allowed]);
  const [term, setTerm] = useState('');
  const [found, setFound] = useState<{ id: string; name: string }[]>([]);
  const [open, setOpen] = useState<MediaPerson | null>(null);
  const [reason, setReason] = useState('');
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);

  async function run(fn: () => Promise<unknown>, ok: string) {
    setBusy(true); setErr(''); setMsg('');
    try { await fn(); setMsg(ok); await people.reload(); } catch (e) { setErr(friendlyError(e)); } finally { setBusy(false); }
  }
  const current = open ? (people.data ?? []).find((x) => x.userId === open.userId) ?? null : null;

  return (
    <MediaScreen loading={roles.loading || people.loading} error={roles.error || people.error} onRetry={() => { void people.reload(); }} denied={roles.data && !allowed ? 'Only administrators can manage Media staff.' : undefined}>
      <Text style={s.title}>Media staff</Text>
      {err ? <Notice tone="error">{err}</Notice> : null}
      {msg ? <Notice>{msg}</Notice> : null}

      {!current ? (
        <>
          {(people.data ?? []).map((x) => <Card key={x.userId} title={x.name} note={TITLE_LABEL[x.title] ?? x.title} meta={x.overrides.length ? `${x.overrides.length} custom permission(s)` : undefined} onPress={() => { setOpen(x); setReason(''); }} />)}
          <SectionTitle>Appoint someone</SectionTitle>
          <Field label="Search by name" value={term} onChangeText={setTerm} />
          <Button title="Search" variant="secondary" onPress={() => void findPeople(term).then(setFound).catch((e) => setErr(friendlyError(e)))} />
          {found.map((f) => <Card key={f.id} title={f.name} right="Appoint" onPress={() => void run(() => grantRole(f.id, 'media'), `${f.name} now works in Media.`).then(() => setFound([]))} />)}
        </>
      ) : (
        <>
          <Button title="Back" variant="secondary" onPress={() => setOpen(null)} />
          <Text style={s.cardTitle}>{current.name}</Text>
          <SectionTitle>Department role</SectionTitle>
          <View style={s.row}>{Object.entries(TITLE_LABEL).map(([k, v]) => <Chip key={k} label={v} selected={current.title === k} onPress={() => void run(() => setMediaTitle(current.userId, k), 'Role updated.')} />)}</View>
          <SectionTitle>Permissions</SectionTitle>
          <Text style={s.muted}>Default follows the Media role. Grant or take away a single permission below; every change is recorded.</Text>
          <Field label="Reason (recorded with the change)" value={reason} onChangeText={setReason} maxLength={300} />
          {(catalogue.data ?? []).map((c) => {
            const o = current.overrides.find((x) => x.permission === c.key);
            return (
              <View key={c.key} style={{ gap: 4 }}>
                <Text style={s.cardTitle}>{c.key}</Text>
                <Text style={s.meta}>{c.description}</Text>
                <View style={s.row}>
                  <Chip label="Default" selected={!o} onPress={() => void run(() => resetPermission(current.userId, c.key), 'Back to the default.')} />
                  <Chip label="Granted" selected={o?.effect === 'grant'} onPress={() => void run(() => grantPermission(current.userId, c.key, reason), 'Granted.')} />
                  <Chip label="Taken away" selected={o?.effect === 'revoke'} onPress={() => void run(() => revokePermission(current.userId, c.key, reason), 'Taken away.')} />
                </View>
              </View>
            );
          })}
          <SectionTitle>Remove from Media</SectionTitle>
          <Text style={s.muted}>Access ends immediately, including any extra permissions.</Text>
          <Button title="Remove from Media" variant="danger" loading={busy} onPress={() => void run(() => revokeRole(current.userId, 'media'), 'Removed. Access has ended.').then(() => setOpen(null))} />
        </>
      )}
    </MediaScreen>
  );
}
