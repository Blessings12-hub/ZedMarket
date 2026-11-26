import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useMemo, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Notice, SectionTitle } from '../../src/components/ui';
import { fetchAccess, fetchWorkload } from '../../src/features/trust-workload/api';
import { needsAttention, type AccessRow, type Counts, type Workload } from '../../src/features/trust-workload/domain';
import { friendlyError } from '../../src/lib/errors';
import { singleFlight } from '../../src/lib/singleFlight';
import { colors, radius, spacing } from '../../src/theme';

export default function TrustWorkload() {
  const router = useRouter();
  const [w, setW] = useState<Workload | null>(null);
  const [access, setAccess] = useState<AccessRow[] | null>(null);
  const [hours, setHours] = useState(24);
  const [error, setError] = useState('');
  const [accessError, setAccessError] = useState('');

  const load = useMemo(() => singleFlight(async (h: number) => {
    try { setW(await fetchWorkload()); setError(''); } catch (e) { setError(friendlyError(e)); }
    try { setAccess(await fetchAccess(h)); setAccessError(''); } catch (e) { setAccessError(friendlyError(e)); setAccess([]); }
  }), []);
  useFocusEffect(useCallback(() => { void load(hours); }, [load, hours]));

  if (!w) {
    return (
      <View style={styles.center}>
        {error ? <><Notice tone="error">{error}</Notice><Button title="Try again" onPress={() => void load(hours)} /></> : <ActivityIndicator color={colors.primary} />}
      </View>
    );
  }
  const block = (title: string, c: Counts, path: '/trust/seller-applications' | '/trust/business-applications') => (
    <View style={styles.card}>
      <Text style={styles.title}>{title}{needsAttention(c) > 0 ? `  ·  ${needsAttention(c)} need attention` : ''}</Text>
      <Text style={styles.text}>New {c.submitted} · In review {c.under_review} · Waiting for applicant {c.info_requested}</Text>
      <Text style={styles.text}>Unassigned {c.unassigned} · Escalated {c.escalated} · Overdue {c.overdue} · Needs second officer {c.awaiting_second}</Text>
      <Button title="Open queue" variant="secondary" onPress={() => router.push(path)} />
    </View>
  );
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Notice>You have {w.mine} open application(s). Escalated applications are overdue after {w.escalationDueHours} hours: {w.escalationsOverdue} right now.</Notice>
      {block('Seller applications', w.seller, '/trust/seller-applications')}
      {block('Business applications', w.business, '/trust/business-applications')}
      <SectionTitle>Who holds the work</SectionTitle>
      {w.officers.length === 0 ? <Text style={styles.text}>Nothing is assigned.</Text> : w.officers.map((o) => <Text key={o.id} style={styles.text}>{o.name}: {o.open} open</Text>)}
      <SectionTitle>Document and ID access</SectionTitle>
      <View style={styles.chips}>{[24, 72, 168].map((h) => <Chip key={h} label={h === 24 ? 'Last day' : h === 72 ? '3 days' : '7 days'} selected={hours === h} onPress={() => setHours(h)} />)}</View>
      {accessError ? <Notice tone="error">{accessError}</Notice> : null}
      {access?.length === 0 && !accessError ? <Text style={styles.text}>No documents or ID details opened in this time.</Text> : null}
      {access?.map((a) => (
        <View key={a.officerId} style={styles.card}>
          <Text style={styles.title}>{a.name}{a.flagged ? '  ·  unusually many opens' : ''}</Text>
          <Text style={styles.text}>{a.documentOpens} document(s) · {a.privateViews} ID/private view(s) · {a.people} people</Text>
        </View>
      ))}
      <Text style={styles.text}>Looking at this page is itself recorded in the audit trail.</Text>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl * 2 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  text: { fontSize: 13, color: colors.muted },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
});
