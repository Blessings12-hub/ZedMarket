import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Chip, Notice, SectionTitle } from '../../../src/components/ui';
import { num, numOrNull, percentText, PERIODS } from '../../../src/domain/analytics';
import { formatKwacha } from '../../../src/domain/money';
import { fetchListingPerformance } from '../../../src/features/analytics/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

export default function ListingNumbers() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [days, setDays] = useState<number>(30);
  const [d, setD] = useState<any | null>(null);
  const [error, setError] = useState('');

  const load = useCallback(() => {
    if (!id) return;
    fetchListingPerformance(id, days).then((r) => { setD(r); setError(''); }).catch((e) => setError(friendlyError(e)));
  }, [id, days]);
  useFocusEffect(load);

  if (!d && !error) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  const rows: [string, string][] = d ? [
    ['Views', String(num(d.views))],
    ['People who looked', String(num(d.unique_viewers))],
    ['Saved in this period', String(num(d.saves_in_period))],
    ['Saved in total', String(num(d.saves_total))],
    ['Chats started', String(num(d.chats_started))],
    ['Orders requested', String(num(d.orders_requested))],
    ['Orders completed', String(num(d.orders_completed))],
    ['Sold (item price only)', formatKwacha(num(d.completed_value_zmw))],
    ['Looked, then chatted', percentText(numOrNull(d.chat_rate_pct))],
    ['Looked, then ordered', percentText(numOrNull(d.order_rate_pct))],
    ['Days listed', String(num(d.days_listed))],
  ] : [];

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {d ? <Text style={styles.title}>{d.title}</Text> : null}
      <View style={styles.row}>
        {PERIODS.map((p) => <Chip key={p} label={`${p} days`} selected={days === p} onPress={() => setDays(p)} />)}
      </View>
      {d ? <SectionTitle>{`Price ${formatKwacha(num(d.price_zmw))}`}</SectionTitle> : null}
      {rows.map(([label, value]) => (
        <View key={label} style={styles.line}>
          <Text style={styles.label}>{label}</Text>
          <Text style={styles.value}>{value}</Text>
        </View>
      ))}
      {d?.low_stock_at !== undefined && d?.stock !== null && d?.stock !== undefined ? (
        <Text style={styles.label}>Stock left: {String(d.stock)}</Text>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.sm },
  center: { flex: 1, justifyContent: 'center', backgroundColor: colors.background },
  title: { fontSize: 20, fontWeight: '700', color: colors.text },
  row: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' },
  line: { flexDirection: 'row', justifyContent: 'space-between', backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md },
  label: { fontSize: 15, color: colors.muted },
  value: { fontSize: 15, fontWeight: '600', color: colors.text },
});
