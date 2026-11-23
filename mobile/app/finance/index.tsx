import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { canSeeFinance, type AdminRole } from '../../src/domain/admin';
import { formatKwacha } from '../../src/domain/money';
import { methodLabel, statusLabel } from '../../src/domain/payments';
import { fetchAssurance, fetchMyRoles } from '../../src/features/admin/api';
import { fetchFinancePayments, fetchSummary, type FinanceRow, type SummaryRow } from '../../src/features/payments/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

const SUMMARY_LABELS: Record<string, string> = {
  pending: 'Waiting', succeeded: 'Paid', failed: 'Failed', cancelled: 'Cancelled', refunded: 'Refunded',
  refunds_waiting: 'Refunds waiting', needs_review: 'Need checking', stale_pending: 'Waiting over an hour late',
};
const FILTERS: { key: string | null; label: string }[] = [
  { key: null, label: 'All' }, { key: 'pending', label: 'Waiting' }, { key: 'succeeded', label: 'Paid' },
  { key: 'failed', label: 'Failed' }, { key: 'cancelled', label: 'Cancelled' },
];

export default function FinanceHome() {
  const router = useRouter();
  const { userId } = useAuth();
  const [roles, setRoles] = useState<AdminRole[] | null>(null);
  const [twoFactor, setTwoFactor] = useState(false);
  const [summary, setSummary] = useState<SummaryRow[]>([]);
  const [rows, setRows] = useState<FinanceRow[]>([]);
  const [status, setStatus] = useState<string | null>(null);
  const [review, setReview] = useState(false);
  const [search, setSearch] = useState('');
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      const [myRoles, level] = await Promise.all([fetchMyRoles(userId), fetchAssurance()]);
      setRoles(myRoles);
      const ok = level.currentLevel === 'aal2';
      setTwoFactor(ok);
      if (canSeeFinance(myRoles) && ok) {
        const [s, p] = await Promise.all([fetchSummary(30), fetchFinancePayments(status, review, search)]);
        setSummary(s);
        setRows(p);
      }
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [userId, status, review, search]);

  useFocusEffect(useCallback(() => { void load(); }, [load]));

  if (!roles && !error) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  if (!roles || !canSeeFinance(roles)) {
    return (
      <View style={styles.center}>
        {error ? <Notice tone="error">{error}</Notice> : null}
        <Text style={styles.title}>Finance staff only</Text>
      </View>
    );
  }
  if (!twoFactor) {
    return (
      <View style={styles.center}>
        <Text style={styles.title}>Two-factor sign-in needed</Text>
        <Text style={styles.meta}>Payment records stay locked until you sign in with your authenticator code.</Text>
        <Button title="Go to Staff tools to sign in" onPress={() => router.push('/admin')} />
      </View>
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.title}>Finance</Text>
      <Text style={styles.meta}>Last 30 days. ZedMarket records payments; it does not hold customer money.</Text>
      <View style={styles.grid}>
        {summary.map((s) => (
          <View key={s.label} style={styles.tile}>
            <Text style={styles.tileNum}>{s.count}</Text>
            <Text style={styles.tileLabel}>{SUMMARY_LABELS[s.label] ?? s.label}</Text>
            <Text style={styles.tileAmt}>{formatKwacha(s.amount)}</Text>
          </View>
        ))}
      </View>
      <Button title="Refund requests" variant="secondary" onPress={() => router.push('/finance/refunds')} />

      <SectionTitle>Payments</SectionTitle>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.chips}>
        {FILTERS.map((f) => (
          <Chip key={f.label} label={f.label} selected={!review && status === f.key} onPress={() => { setReview(false); setStatus(f.key); }} />
        ))}
        <Chip label="Need checking" selected={review} onPress={() => { setStatus(null); setReview(true); }} />
      </ScrollView>
      <Field label="Search by payment, order or provider reference" value={search} onChangeText={setSearch} autoCapitalize="characters" />
      {rows.length === 0 ? <Text style={styles.meta}>Nothing matches.</Text> : null}
      {rows.map((r) => (
        <Pressable key={r.id} style={[styles.card, r.needsReview && styles.flag]} onPress={() => router.push(`/finance/payment/${r.id}`)} accessibilityRole="button">
          <Text style={styles.rowTitle}>{r.ref} · {formatKwacha(r.amount)}</Text>
          <Text style={styles.meta}>{r.orderRef} · {methodLabel(r.method)} · {r.phone}</Text>
          <Text style={styles.meta}>{statusLabel(r.status, r.needsReview)}{r.openRefunds > 0 ? ` · ${r.openRefunds} refund open` : ''}</Text>
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
  meta: { fontSize: 13, color: colors.muted, lineHeight: 19 },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  tile: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, minWidth: '47%', flexGrow: 1, borderWidth: 1, borderColor: colors.border },
  tileNum: { fontSize: 22, fontWeight: '700', color: colors.text },
  tileLabel: { fontSize: 13, color: colors.muted },
  tileAmt: { fontSize: 13, color: colors.text },
  chips: { gap: spacing.sm },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: 4, borderWidth: 1, borderColor: colors.border },
  flag: { borderColor: colors.warning, backgroundColor: colors.warningSoft },
  rowTitle: { fontSize: 15, fontWeight: '700', color: colors.text },
});
