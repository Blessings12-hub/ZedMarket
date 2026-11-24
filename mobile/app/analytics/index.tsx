import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Notice, SectionTitle } from '../../src/components/ui';
import { hoursText, minutesText, num, numOrNull, percentText, PERIODS, ratingText } from '../../src/domain/analytics';
import { formatKwacha } from '../../src/domain/money';
import { fetchEngagement, fetchSellerAnalytics } from '../../src/features/analytics/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

function Stat({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <View style={styles.stat}>
      <Text style={styles.statValue}>{value}</Text>
      <Text style={styles.statLabel}>{label}</Text>
      {hint ? <Text style={styles.statHint}>{hint}</Text> : null}
    </View>
  );
}

export default function SellerNumbers() {
  const router = useRouter();
  const { business } = useLocalSearchParams<{ business?: string }>();
  const scope = business ?? null;
  const [days, setDays] = useState<number>(30);
  const [data, setData] = useState<any | null>(null);
  const [eng, setEng] = useState<any | null>(null);
  const [error, setError] = useState('');

  const load = useCallback(() => {
    Promise.all([fetchSellerAnalytics(scope, days), fetchEngagement(scope, days)])
      .then(([a, e]) => { setData(a); setEng(e); setError(''); })
      .catch((e) => setError(friendlyError(e)));
  }, [scope, days]);
  useFocusEffect(load);

  if (!data && !error) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  const f = data?.funnel ?? {};
  const s = data?.sales ?? {};
  const h = data?.order_handling ?? {};
  const noViews = (data?.views_period_days ?? days) < days;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Text style={styles.title}>{scope ? 'Business numbers' : 'My selling numbers'}</Text>
      <View style={styles.row}>
        {PERIODS.map((p) => <Chip key={p} label={`${p} days`} selected={days === p} onPress={() => setDays(p)} />)}
      </View>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {data ? (
        <>
          {noViews ? <Notice>Views are only kept for 90 days, so view numbers cover the last {data.views_period_days} days.</Notice> : null}
          <SectionTitle>Sales</SectionTitle>
          <View style={styles.grid}>
            <Stat label="Completed orders" value={String(num(s.completed_orders))} />
            <Stat label="Sold (items only)" value={formatKwacha(num(s.completed_value_zmw))} hint="Delivery fees are not included" />
            <Stat label="Average order" value={numOrNull(s.average_order_zmw) === null ? 'No data yet' : formatKwacha(num(s.average_order_zmw))} />
            <Stat label="Active listings" value={String(num(data.active_listings))} />
          </View>
          <SectionTitle>From views to orders</SectionTitle>
          <View style={styles.grid}>
            <Stat label="Views" value={String(num(f.views))} />
            <Stat label="People who looked" value={String(num(f.unique_viewers))} />
            <Stat label="Chats started" value={String(num(f.chats_started))} />
            <Stat label="Orders requested" value={String(num(f.orders_requested))} />
            <Stat label="Saved by buyers" value={String(num(data.saves_in_period))} />
            <Stat label="Looked, then ordered" value={percentText(numOrNull(f.order_rate_pct))} />
          </View>
          <SectionTitle>How orders went</SectionTitle>
          <View style={styles.grid}>
            <Stat label="Time to confirm" value={hoursText(numOrNull(h.avg_hours_to_confirm))} />
            <Stat label="Time to complete" value={hoursText(numOrNull(h.avg_hours_to_complete))} />
            <Stat label="Not completed" value={percentText(numOrNull(h.not_completed_pct))} hint={`${num(h.declined)} declined, ${num(h.cancelled)} cancelled, ${num(h.expired)} expired`} />
            <Stat label="In dispute" value={String(num(h.disputed))} />
          </View>
          <Text style={styles.text}>{ratingText(numOrNull(data.reviews?.average), num(data.reviews?.count))}</Text>
          {eng ? (
            <>
              <SectionTitle>Customers and replies</SectionTitle>
              <View style={styles.grid}>
                <Stat label="Chats answered" value={percentText(numOrNull(eng.reply_rate_pct))} />
                <Stat label="First reply takes" value={minutesText(numOrNull(eng.avg_first_reply_minutes))} />
                <Stat label="Waiting over 24 hours" value={String(num(eng.unanswered_over_24h))} hint="Buyers still waiting for you" />
                <Stat label="Repeat customers" value={String(num(eng.repeat_customers))} hint="Bought from you more than once" />
              </View>
            </>
          ) : null}
          {(data.top_listings ?? []).length > 0 ? (
            <>
              <SectionTitle>Your best listings</SectionTitle>
              {(data.top_listings as any[]).map((l) => (
                <View key={l.id} style={styles.card}>
                  <Text style={styles.cardTitle}>{l.title}</Text>
                  <Text style={styles.text}>{num(l.views)} views, {num(l.saves)} saves, {num(l.completed)} sold</Text>
                  <Button title="See this listing's numbers" variant="secondary" onPress={() => router.push({ pathname: '/analytics/listing/[id]', params: { id: l.id } })} />
                </View>
              ))}
            </>
          ) : null}
          <Button title="Sales report" onPress={() => router.push({ pathname: '/analytics/sales', params: scope ? { business: scope } : {} })} />
          <Text style={styles.small}>Times are Zambia time. Only your own listings and orders are counted, and buyers are never named here.</Text>
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, justifyContent: 'center', backgroundColor: colors.background },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  row: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  stat: { flexGrow: 1, flexBasis: '45%', backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 2 },
  statValue: { fontSize: 20, fontWeight: '700', color: colors.text },
  statLabel: { fontSize: 13, color: colors.muted },
  statHint: { fontSize: 12, color: colors.muted },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  cardTitle: { fontSize: 16, fontWeight: '600', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  small: { fontSize: 12, color: colors.muted },
});
