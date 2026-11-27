import { useState } from 'react';
import { Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Field, Notice, SectionTitle } from '../../src/components/ui';
import { canManageTeam } from '../../src/domain/admin';
import { fetchMyRoles, fetchTeam } from '../../src/features/admin/api';
import { listAccessPauses, resetPermission, revokePermission } from '../../src/features/media/api';
import { PAUSABLE } from '../../src/features/media/domain';
import { MediaScreen, styles as s } from '../../src/features/media/ui';
import { useLoad } from '../../src/features/media/useLoad';
import { friendlyError } from '../../src/lib/errors';

// Administrators only. Pausing keeps the person on the team but switches off one department's tools until restored.
// It can only take away what the role gives; it never adds anything.
export default function StaffAccess() {
  const { userId } = useAuth();
  const roles = useLoad(async () => (userId ? fetchMyRoles(userId) : []), [userId]);
  const allowed = canManageTeam(roles.data ?? []);
  const data = useLoad(async () => (allowed ? { team: await fetchTeam(), paused: await listAccessPauses() } : null), [allowed]);
  const [reason, setReason] = useState('');
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);

  async function act(fn: () => Promise<void>, ok: string) {
    setBusy(true); setErr(''); setMsg('');
    try { await fn(); setMsg(ok); await data.reload(); } catch (e) { setErr(friendlyError(e)); } finally { setBusy(false); }
  }
  const rows = (data.data?.team ?? []).filter((m) => PAUSABLE[m.role]);

  return (
    <MediaScreen loading={roles.loading || data.loading} error={roles.error || data.error} onRetry={() => void data.reload()} denied={roles.data && !allowed ? 'Only administrators can pause or restore access.' : undefined}>
      <Text style={s.title}>Pause or restore access</Text>
      <Text style={s.muted}>Pausing switches off one department's tools for one person straight away. They stay on the team. Every change is recorded.</Text>
      {err ? <Notice tone="error">{err}</Notice> : null}
      {msg ? <Notice>{msg}</Notice> : null}
      <Field label="Reason (recorded with the change)" value={reason} onChangeText={setReason} maxLength={300} />
      {rows.map((m) => {
        const info = PAUSABLE[m.role];
        if (!info) return null;
        const paused = (data.data?.paused ?? []).some((x) => x.userId === m.userId && x.permission === info.key);
        return (
          <View key={`${m.userId}-${m.role}`} style={{ gap: 6 }}>
            <SectionTitle>{`${m.name} · ${info.label}`}</SectionTitle>
            <Text style={s.meta}>{paused ? 'Paused' : 'Active'}</Text>
            {paused ? (
              <Button title="Restore access" variant="secondary" loading={busy} onPress={() => void act(() => resetPermission(m.userId, info.key), 'Access restored.')} />
            ) : (
              <Button title="Pause access" variant="danger" loading={busy} disabled={m.userId === userId}
                onPress={() => void act(() => revokePermission(m.userId, info.key, reason), 'Access paused.')} />
            )}
          </View>
        );
      })}
      {data.data && rows.length === 0 ? <Text style={s.muted}>No Support, Moderation or Finance staff yet.</Text> : null}
    </MediaScreen>
  );
}
