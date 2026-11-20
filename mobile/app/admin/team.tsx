import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { ROLE_LABELS, type AdminRole } from '../../src/domain/admin';
import {
  decideApproval,
  fetchPendingApprovals,
  fetchTeam,
  findPeople,
  grantRole,
  revokeRole,
  type Approval,
  type StaffMember,
} from '../../src/features/admin/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

const ROLES: AdminRole[] = ['support', 'moderator', 'finance', 'tech_admin'];

export default function Team() {
  const { userId } = useAuth();
  const [team, setTeam] = useState<StaffMember[]>([]);
  const [approvals, setApprovals] = useState<Approval[]>([]);
  const [term, setTerm] = useState('');
  const [people, setPeople] = useState<{ id: string; name: string }[]>([]);
  const [chosen, setChosen] = useState<{ id: string; name: string } | null>(null);
  const [role, setRole] = useState<AdminRole | null>(null);
  const [revoking, setRevoking] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [t, a] = await Promise.all([fetchTeam(), fetchPendingApprovals()]);
      setTeam(t);
      setApprovals(a);
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  async function search() {
    try {
      setPeople(await findPeople(term));
    } catch (e) {
      setError(friendlyError(e));
    }
  }

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError('');
    try {
      await action();
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  const key = (m: StaffMember) => `${m.userId}:${m.role}`;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}

      <SectionTitle>Current staff</SectionTitle>
      {team.map((m) => (
        <View key={key(m)} style={styles.card}>
          <Text style={styles.title}>{m.name}</Text>
          <Text style={styles.meta}>
            {ROLE_LABELS[m.role]} · since {new Date(m.grantedAt).toLocaleDateString()}
          </Text>
          {revoking === key(m) ? (
            <>
              <Button title="Yes, remove this role" variant="danger" onPress={() => run(async () => { await revokeRole(m.userId, m.role); setRevoking(null); })} loading={busy} />
              <Button title="Keep it" variant="secondary" onPress={() => setRevoking(null)} disabled={busy} />
            </>
          ) : m.userId === userId && m.role === 'tech_admin' ? null : (
            <Button title="Remove role" variant="secondary" onPress={() => setRevoking(key(m))} />
          )}
        </View>
      ))}

      <SectionTitle>Give someone a role</SectionTitle>
      <Field label="Search by name" value={term} onChangeText={setTerm} onSubmitEditing={search} returnKeyType="search" />
      <Button title="Search" variant="secondary" onPress={search} />
      {people.map((p) => (
        <Chip key={p.id} label={p.name} selected={chosen?.id === p.id} onPress={() => setChosen(p)} />
      ))}
      {chosen ? (
        <>
          <Text style={styles.meta}>Role for {chosen.name}:</Text>
          <View style={styles.row}>
            {ROLES.map((r) => (
              <Chip key={r} label={ROLE_LABELS[r]} selected={role === r} onPress={() => setRole(r)} />
            ))}
          </View>
          <Button
            title="Give role"
            disabled={!role}
            loading={busy}
            onPress={() =>
              run(async () => {
                if (!role) return;
                await grantRole(chosen.id, role);
                setChosen(null);
                setRole(null);
                setPeople([]);
                setTerm('');
              })
            }
          />
          <Text style={styles.meta}>They will still need to set up two-factor sign-in before the role works.</Text>
        </>
      ) : null}

      {approvals.length > 0 ? <SectionTitle>Waiting for a second person</SectionTitle> : null}
      {approvals.map((a) => (
        <View key={a.id} style={styles.card}>
          <Text style={styles.title}>{a.action.replace(/[._]/g, ' ')}</Text>
          <Text style={styles.meta}>{new Date(a.createdAt).toLocaleString()}</Text>
          {a.requestedBy === userId ? (
            <Text style={styles.meta}>You asked for this, so someone else has to decide.</Text>
          ) : (
            <>
              <Button title="Approve" onPress={() => run(() => decideApproval(a.id, true))} loading={busy} />
              <Button title="Reject" variant="secondary" onPress={() => run(() => decideApproval(a.id, false))} disabled={busy} />
            </>
          )}
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  title: { fontSize: 17, fontWeight: '600', color: colors.text, textTransform: 'capitalize' },
  meta: { fontSize: 13, color: colors.muted },
});
