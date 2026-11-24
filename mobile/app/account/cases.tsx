import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Notice, SectionTitle } from '../../src/components/ui';
import { fetchMyCases } from '../../src/features/account-hub/api';
import { APPEAL_STATUS_LABELS, DISPUTE_STATUS_LABELS } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

type Cases = Awaited<ReturnType<typeof fetchMyCases>>;

// Customer-facing only. Staff queues stay under Staff tools.
export default function MyCases() {
  const router = useRouter();
  const { userId } = useAuth();
  const [cases, setCases] = useState<Cases | null>(null);
  const [error, setError] = useState('');

  useFocusEffect(
    useCallback(() => {
      if (!userId) return;
      fetchMyCases(userId).then((c) => { setCases(c); setError(''); }).catch((e) => { setCases({ disputes: [], appeals: [], reports: [] }); setError(friendlyError(e)); });
    }, [userId]),
  );

  if (!cases) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <SectionTitle>Disputes</SectionTitle>
      {cases.disputes.length === 0 ? <Text style={styles.hint}>No disputes. If an order goes wrong, open it from "My orders" and choose "Report a problem".</Text> : null}
      {cases.disputes.map((d) => (
        <Pressable key={d.id} accessibilityRole="button" style={styles.card} onPress={() => router.push({ pathname: '/dispute/[id]', params: { id: d.id } })}>
          <Text style={styles.title}>{d.reason}</Text>
          <Text style={styles.hint}>{DISPUTE_STATUS_LABELS[d.status]} · {d.createdAt.slice(0, 10)}</Text>
          {d.outcome ? <Text style={styles.body}>{d.outcome}</Text> : null}
        </Pressable>
      ))}

      <SectionTitle>Appeals</SectionTitle>
      {cases.appeals.length === 0 ? <Text style={styles.hint}>No appeals. If a listing or your account is restricted, you can appeal from the Profile tab or from My products.</Text> : null}
      {cases.appeals.map((a) => (
        <View key={a.id} style={styles.card}>
          <Text style={styles.title}>Appeal about a {a.targetType}</Text>
          <Text style={styles.hint}>{APPEAL_STATUS_LABELS[a.status]} · {a.createdAt.slice(0, 10)}</Text>
          {a.reviewerNote ? <Text style={styles.body}>{a.reviewerNote}</Text> : null}
        </View>
      ))}

      <SectionTitle>Reports you made</SectionTitle>
      {cases.reports.length === 0 ? <Text style={styles.hint}>You have not reported anything.</Text> : null}
      {cases.reports.map((r) => (
        <View key={r.id} style={styles.card}>
          <Text style={styles.title}>{r.targetType.replace(/_/g, ' ')}: {r.reason.replace(/_/g, ' ')}</Text>
          <Text style={styles.hint}>{r.status.replace(/_/g, ' ')} · {r.createdAt.slice(0, 10)}</Text>
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.sm },
  center: { flex: 1, justifyContent: 'center', backgroundColor: colors.background },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 2 },
  title: { fontSize: 15, fontWeight: '600', color: colors.text },
  body: { fontSize: 14, color: colors.text, lineHeight: 20, marginTop: 4 },
  hint: { fontSize: 13, color: colors.muted, lineHeight: 18 },
});
