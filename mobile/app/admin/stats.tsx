import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Chip, Notice, SectionTitle } from '../../src/components/ui';
import { canReadTrust, canSeeFinance, canManageTeam, type AdminRole } from '../../src/domain/admin';
import { hoursText, lusakaDate, num, numOrNull, percentText, PERIODS } from '../../src/domain/analytics';
import { formatKwacha } from '../../src/domain/money';
import { fetchAssurance, fetchMyRoles } from '../../src/features/admin/api';
import { fetchFinanceTotals, fetchPlatformStats, fetchTrustStats } from '../../src/features/analytics/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

function Line({ label, value }: { label: string; value: string }) {
  return (
    <View style={styles.line}>
      <Text style={styles.label}>{label}</Text>
      <Text style={styles.value}>{value}</Text>
    </View>
  );
}

function counts(o: Record<string, unknown> | undefined): [string, string][] {
  return Object.entries(o ?? {}).map(([k, v]) => [k.replace(/_/g, ' '), String(num(v))]);
}

export default function Statistics() {
  const { userId } = useAuth();
  const [roles, setRoles] = useState<AdminRole[] | null>(null);
  const [twoFactor, setTwoFactor] = useState(false);
  const [days, setDays] = useState<number>(30);
  const [platform, setPlatform] = useState<any | null>(null);
  const [trust, setTrust] = useState<any | null>(null);
  const [money, setMoney] = useState<any | null>(null);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      const [myRoles, level] = await Promise.all([fetchMyRoles(userId), fetchAssurance()]);
      setRoles(myRoles);
      const ok = level.currentLevel === 'aal2';
      setTwoFactor(ok);
      if (!ok) return;
      const wantsPlatform = canSeeFinance(myRoles) || canManageTeam(myRoles); // the database allows finance and technical admin
      const wantsTrust = canReadTrust(myRoles) || canManageTeam(myRoles);
      const to = lusakaDate(new Date());
      const from = lusakaDate(new Date(), days);
      const [p, t, m] = await Promise.all([
        wantsPlatform ? fetchPlatformStats(days) : Promise.resolve(null),
        wantsTrust ? fetchTrustStats(days) : Promise.resolve(null),
        wantsPlatform ? fetchFinanceTotals(from, to) : Promise.resolve(null),
      ]);
      setPlatform(p); setTrust(t); setMoney(m); setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [userId, days]);
  useFocusEffect(useCallback(() => { void load(); }, [load]));

  if (!roles && !error) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  if (roles && roles.length === 0) return <View style={styles.center}><Notice tone="error">This page is for staff only.</Notice></View>;
  if (roles && !twoFactor) return <View style={styles.center}><Notice tone="warning">Staff pages need your second sign-in step. Open Staff tools and complete it first.</Notice></View>;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Text style={styles.title}>Platform statistics</Text>
      <View style={styles.row}>{PERIODS.map((p) => <Chip key={p} label={`${p} days`} selected={days === p} onPress={() => setDays(p)} />)}</View>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {platform ? (
        <>
          <SectionTitle>Marketplace</SectionTitle>
          <Line label="People signed up (all time)" value={String(num(platform.users?.total))} />
          <Line label="New people" value={String(num(platform.users?.new))} />
          <Line label="Businesses" value={`${num(platform.businesses?.total)} (${num(platform.businesses?.new)} new)`} />
          <Line label="Active listings" value={String(num(platform.listings?.active))} />
          <Line label="New listings" value={String(num(platform.listings?.new))} />
          <Line label="Orders requested" value={String(num(platform.orders?.created))} />
          <Line label="Orders completed" value={String(num(platform.orders?.completed))} />
          <Line label="Agreed value of completed orders" value={formatKwacha(num(platform.orders?.agreed_value_completed_zmw))} />
          <Line label="Orders not completed" value={percentText(numOrNull(platform.orders?.not_completed_pct))} />
          <Line label="Chats started" value={String(num(platform.conversations_started))} />
        </>
      ) : null}
      {trust ? (
        <>
          <SectionTitle>Reports, disputes and appeals</SectionTitle>
          <Line label="Reports opened" value={String(num(trust.reports?.opened))} />
          <Line label="Reports open now" value={String(num(trust.reports?.open_now))} />
          <Line label="Oldest open report" value={hoursText(numOrNull(trust.reports?.oldest_open_hours))} />
          <Line label="Time to decide a report" value={hoursText(numOrNull(trust.reports?.avg_hours_to_decide))} />
          <Line label="Disputes opened" value={String(num(trust.disputes?.opened))} />
          <Line label="Disputes open now" value={String(num(trust.disputes?.open_now))} />
          <Line label="Disputes as a share of orders" value={percentText(numOrNull(trust.disputes?.dispute_rate_pct))} />
          <Line label="Appeals opened" value={String(num(trust.appeals?.opened))} />
          <Line label="Appeals overturned" value={percentText(numOrNull(trust.appeals?.overturn_rate_pct))} />
          <Line label="Risk flags open" value={String(num(trust.risk_flags?.open_now))} />
          <Line label="Restricted accounts now" value={String(num(trust.accounts?.restricted_now))} />
          <Line label="Suspended accounts now" value={String(num(trust.accounts?.suspended_now))} />
          {counts(trust.reports?.by_reason).map(([k, v]) => <Line key={k} label={`Reports: ${k}`} value={v} />)}
        </>
      ) : null}
      {money ? (
        <>
          <SectionTitle>Payments in the app</SectionTitle>
          <Notice>Only payments made through ZedMarket appear here. Most deals are paid in person, so this is not the value of all sales.</Notice>
          <Line label="Paid in the app" value={formatKwacha(num(money.paid_in_app_zmw))} />
          <Line label="Refunded" value={formatKwacha(num(money.refunded_zmw))} />
          <Line label="Agreed value of completed orders" value={formatKwacha(num(money.agreed_value_completed_orders_zmw))} />
          <Line label="Share paid in the app" value={percentText(numOrNull(money.paid_in_app_share_pct))} />
          <Line label="Payments needing a check" value={`${num(money.needs_review_now?.count)} (${formatKwacha(num(money.needs_review_now?.amount_zmw))})`} />
          <Text style={styles.small}>Opening this section is recorded in the audit log.</Text>
        </>
      ) : null}
      {roles && !platform && !trust && !money && !error ? <Notice>Your role does not include any statistics.</Notice> : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.sm },
  center: { flex: 1, padding: spacing.xl, justifyContent: 'center', backgroundColor: colors.background },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  row: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' },
  line: { flexDirection: 'row', justifyContent: 'space-between', gap: spacing.sm, backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md },
  label: { fontSize: 15, color: colors.muted, flex: 1 },
  value: { fontSize: 15, fontWeight: '600', color: colors.text },
  small: { fontSize: 12, color: colors.muted },
});
