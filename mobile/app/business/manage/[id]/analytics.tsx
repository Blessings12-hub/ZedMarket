import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Chip, Notice, SectionTitle } from '../../../../src/components/ui';
import { PERIODS, type AnalyticsPeriod } from '../../../../src/domain/business';
import { formatKwacha } from '../../../../src/domain/money';
import { fetchAnalytics, type Analytics } from '../../../../src/features/business/api';
import { friendlyError } from '../../../../src/lib/errors';
import { colors, radius, spacing } from '../../../../src/theme';

function Tile({ label, value }: { label: string; value: string }) {
  return (
    <View style={styles.tile}>
      <Text style={styles.value}>{value}</Text>
      <Text style={styles.meta}>{label}</Text>
    </View>
  );
}

export default function BusinessAnalytics() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [days, setDays] = useState<AnalyticsPeriod>(30);
  const [data, setData] = useState<Analytics | null>(null);
  const [error, setError] = useState('');

  useFocusEffect(
    useCallback(() => {
      if (!id) return;
      fetchAnalytics(id, days)
        .then((a) => {
          setData(a);
          setError('');
        })
        .catch((e) => setError(friendlyError(e)));
    }, [id, days]),
  );

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <View style={styles.row}>
        {PERIODS.map((p) => (
          <Chip key={p} label={`${p} days`} selected={days === p} onPress={() => setDays(p)} />
        ))}
      </View>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Notice>ZedMarket does not handle payment, so "completed value" is the listed price of orders marked completed, not money received.</Notice>
      {data ? (
        <>
          <View style={styles.grid}>
            <Tile label="Orders received" value={String(data.ordersReceived)} />
            <Tile label="Completed orders" value={String(data.completedOrders)} />
            <Tile label="Completed value" value={formatKwacha(data.completedValue)} />
            <Tile label="Open right now" value={String(data.ordersOpenNow)} />
            <Tile label="Listing views" value={String(data.listingViews)} />
            <Tile label="Times saved" value={String(data.savesTotal)} />
            <Tile label="Active listings" value={String(data.activeListings)} />
            <Tile label="Low or out of stock" value={`${data.lowStock} / ${data.outOfStock}`} />
          </View>

          <SectionTitle>Top listings</SectionTitle>
          {data.topListings.length === 0 ? <Text style={styles.meta}>No listings yet.</Text> : null}
          {data.topListings.map((t) => (
            <View key={t.id} style={styles.card}>
              <Text style={styles.name}>{t.title}</Text>
              <Text style={styles.meta}>{t.completed} sold · {t.views} views · {t.saves} saves</Text>
            </View>
          ))}

          <SectionTitle>By branch</SectionTitle>
          {data.byBranch.length === 0 ? <Text style={styles.meta}>No orders in this period.</Text> : null}
          {data.byBranch.map((b) => (
            <View key={b.branch} style={styles.card}>
              <Text style={styles.name}>{b.branch}</Text>
              <Text style={styles.meta}>{b.orders} orders · {formatKwacha(b.completedValue)} completed</Text>
            </View>
          ))}
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  row: { flexDirection: 'row', gap: spacing.sm },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  tile: { flexGrow: 1, flexBasis: '45%', backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md },
  value: { fontSize: 20, fontWeight: '700', color: colors.text },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 2 },
  name: { fontSize: 15, fontWeight: '600', color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
});
