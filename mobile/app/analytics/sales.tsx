import { useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, ScrollView, Share, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Notice, SectionTitle } from '../../src/components/ui';
import { GROUPS, lusakaDate, num, PERIODS, toCsv } from '../../src/domain/analytics';
import { formatKwacha } from '../../src/domain/money';
import { fetchSalesByListing, fetchSalesReport, type ListingSalesRow, type SalesRow } from '../../src/features/analytics/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function SalesReport() {
  const { business } = useLocalSearchParams<{ business?: string }>();
  const scope = business ?? null;
  const [days, setDays] = useState<number>(30);
  const [group, setGroup] = useState<string>('day');
  const [rows, setRows] = useState<SalesRow[] | null>(null);
  const [byListing, setByListing] = useState<ListingSalesRow[]>([]);
  const [error, setError] = useState('');

  const from = lusakaDate(new Date(), days);
  const to = lusakaDate(new Date());

  const load = useCallback(() => {
    setRows(null);
    Promise.all([fetchSalesReport(scope, from, to, group), fetchSalesByListing(scope, from, to)])
      .then(([r, l]) => { setRows(r); setByListing(l); setError(''); })
      .catch((e) => { setRows([]); setError(friendlyError(e)); });
  }, [scope, from, to, group]);
  useEffect(load, [load]);

  const totalItems = (rows ?? []).reduce((n, r) => n + num(r.items_zmw), 0);
  const totalFees = (rows ?? []).reduce((n, r) => n + num(r.delivery_fees_zmw), 0);
  const totalOrders = (rows ?? []).reduce((n, r) => n + num(r.orders_completed), 0);

  async function share() {
    const csv = toCsv(
      ['Period starting', 'Completed orders', 'Items (ZMW)', 'Delivery fees (ZMW)', 'Total (ZMW)'],
      (rows ?? []).map((r) => [r.period, r.orders_completed, num(r.items_zmw), num(r.delivery_fees_zmw), num(r.total_zmw)]),
    );
    try {
      await Share.share({ title: `Sales ${from} to ${to}`, message: csv });
    } catch (e) {
      setError(friendlyError(e));
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Text style={styles.title}>Sales report</Text>
      <Text style={styles.text}>{from} to {to} (Zambia time). Only completed orders are counted, on the day they were completed.</Text>
      <View style={styles.row}>{PERIODS.map((p) => <Chip key={p} label={`${p} days`} selected={days === p} onPress={() => setDays(p)} />)}</View>
      <View style={styles.row}>{GROUPS.map((g) => <Chip key={g.key} label={g.label} selected={group === g.key} onPress={() => setGroup(g.key)} />)}</View>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {!rows ? <ActivityIndicator color={colors.primary} /> : (
        <>
          <View style={styles.total}>
            <Text style={styles.big}>{formatKwacha(totalItems)}</Text>
            <Text style={styles.text}>{totalOrders} completed order{totalOrders === 1 ? '' : 's'}, plus {formatKwacha(totalFees)} delivery fees collected</Text>
          </View>
          {rows.length === 0 ? <Notice>No completed orders in this period.</Notice> : null}
          {rows.map((r) => (
            <View key={r.period} style={styles.line}>
              <Text style={styles.label}>{r.period}</Text>
              <Text style={styles.value}>{r.orders_completed} • {formatKwacha(num(r.items_zmw))}</Text>
            </View>
          ))}
          {byListing.length > 0 ? <SectionTitle>By listing</SectionTitle> : null}
          {byListing.map((l) => (
            <View key={l.listing_id} style={styles.line}>
              <Text style={[styles.label, { flex: 1 }]} numberOfLines={1}>{l.title}</Text>
              <Text style={styles.value}>{l.orders_completed} • {formatKwacha(num(l.items_zmw))}</Text>
            </View>
          ))}
          {rows.length > 0 ? <Button title="Share as a spreadsheet file (CSV text)" variant="secondary" onPress={share} /> : null}
          <Text style={styles.small}>This is a sales summary from the orders recorded in ZedMarket. It is not an accounting or tax statement, and it does not show money paid outside the app.</Text>
        </>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  row: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' },
  total: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 4 },
  big: { fontSize: 24, fontWeight: '700', color: colors.text },
  line: { flexDirection: 'row', justifyContent: 'space-between', gap: spacing.sm, backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md },
  label: { fontSize: 15, color: colors.muted },
  value: { fontSize: 15, fontWeight: '600', color: colors.text },
  text: { fontSize: 14, lineHeight: 20, color: colors.muted },
  small: { fontSize: 12, color: colors.muted },
});
