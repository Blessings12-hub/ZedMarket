import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { canWorkTickets, type AdminRole } from '../../src/domain/admin';
import { metricLabel, staffStatusLabel } from '../../src/domain/support';
import { fetchAssurance, fetchMyRoles } from '../../src/features/admin/api';
import { fetchOverview, fetchQueue, type QueueRow } from '../../src/features/support/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

const VIEWS = [{ key: 'all', label: 'All' }, { key: 'unassigned', label: 'Nobody yet' }, { key: 'mine', label: 'Mine' }];
const SHOWN = ['open_now', 'unassigned_now', 'escalated_now', 'overdue_now', 'waiting_on_customer_now', 'avg_first_response_minutes', 'avg_rating'];

export default function Helpdesk() {
  const router = useRouter();
  const { userId } = useAuth();
  const [roles, setRoles] = useState<AdminRole[] | null>(null);
  const [twoFactor, setTwoFactor] = useState(false);
  const [view, setView] = useState('all');
  const [overdue, setOverdue] = useState(false);
  const [search, setSearch] = useState('');
  const [rows, setRows] = useState<QueueRow[]>([]);
  const [overview, setOverview] = useState<{ metric: string; value: number | null }[]>([]);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      const [myRoles, level] = await Promise.all([fetchMyRoles(userId), fetchAssurance()]);
      setRoles(myRoles);
      const ok = level.currentLevel === 'aal2';
      setTwoFactor(ok);
      if (canWorkTickets(myRoles) && ok) {
        const [q, o] = await Promise.all([fetchQueue(null, view, overdue, search), fetchOverview(30)]);
        setRows(q);
        setOverview(o);
      }
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [userId, view, overdue, search]);
  useFocusEffect(useCallback(() => { void load(); }, [load]));

  if (!roles && !error) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  if (!roles || !canWorkTickets(roles)) {
    return <View style={styles.center}>{error ? <Notice tone="error">{error}</Notice> : null}<Text style={styles.title}>Support staff only</Text></View>;
  }
  if (!twoFactor) {
    return (
      <View style={styles.center}>
        <Text style={styles.title}>Two-factor sign-in needed</Text>
        <Button title="Go to Staff tools to sign in" onPress={() => router.push('/admin')} />
      </View>
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <View style={styles.grid}>
        {SHOWN.map((k) => {
          const m = overview.find((o) => o.metric === k);
          return (
            <View key={k} style={styles.tile}>
              <Text style={styles.num}>{m?.value ?? '–'}</Text>
              <Text style={styles.meta}>{metricLabel(k)}</Text>
            </View>
          );
        })}
      </View>
      <Button title="Team performance" variant="secondary" onPress={() => router.push('/helpdesk/performance')} />

      <SectionTitle>Tickets</SectionTitle>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: spacing.sm }}>
        {VIEWS.map((v) => <Chip key={v.key} label={v.label} selected={view === v.key && !overdue} onPress={() => { setOverdue(false); setView(v.key); }} />)}
        <Chip label="Late" selected={overdue} onPress={() => { setView('all'); setOverdue(true); }} />
      </ScrollView>
      <Field label="Search by reference or title" value={search} onChangeText={setSearch} autoCapitalize="characters" />
      {rows.length === 0 ? <Text style={styles.meta}>Nothing matches.</Text> : null}
      {rows.map((r) => (
        <Pressable key={r.id} style={[styles.card, r.status === 'escalated' && styles.flag]} onPress={() => router.push(`/helpdesk/ticket/${r.id}`)} accessibilityRole="button">
          <Text style={styles.rowTitle}>{r.ref} · {r.subject}</Text>
          <Text style={styles.meta}>
            {staffStatusLabel(r.status)} · {r.priority}{r.overdue ? ' · LATE' : ''} · {r.requester}
          </Text>
          <Text style={styles.meta}>{r.assignedName ? `With ${r.assignedName}` : 'Nobody has taken this yet'}</Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, padding: spacing.xl, gap: spacing.md, justifyContent: 'center', backgroundColor: colors.background },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  tile: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, minWidth: '47%', flexGrow: 1, borderWidth: 1, borderColor: colors.border },
  num: { fontSize: 22, fontWeight: '700', color: colors.text },
  meta: { fontSize: 13, color: colors.muted, lineHeight: 19 },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: 4, borderWidth: 1, borderColor: colors.border },
  flag: { borderColor: colors.warning, backgroundColor: colors.warningSoft },
  rowTitle: { fontSize: 15, fontWeight: '700', color: colors.text },
});
