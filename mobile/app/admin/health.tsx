import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, RefreshControl, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Notice, SectionTitle } from '../../src/components/ui';
import { fetchHealthSummary, type HealthSummary } from '../../src/features/launch/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

// One page for technical admins: is the app crashing, and is any queue getting stuck. Read-only.
export default function Health() {
  const [data, setData] = useState<HealthSummary | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      setData(await fetchHealthSummary());
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useFocusEffect(useCallback(() => { void load(); }, [load]));

  if (loading) return <ActivityIndicator style={{ marginTop: spacing.xl }} color={colors.primary} />;

  const tiles: { label: string; value: number; bad?: boolean }[] = data
    ? [
        { label: 'App crashes (24 hours)', value: data.errors24h, bad: data.errors24h > 0 },
        { label: 'Kinds of crash', value: data.errorKinds24h, bad: data.errorKinds24h > 0 },
        { label: 'Late help tickets', value: data.ticketsLate, bad: data.ticketsLate > 0 },
        { label: 'Tickets with nobody on them', value: data.ticketsUnassigned, bad: data.ticketsUnassigned > 0 },
        { label: 'Seller applications waiting', value: data.sellerApplicationsWaiting },
        { label: 'Listings waiting for review', value: data.listingsWaiting },
        { label: 'Open reports', value: data.reportsOpen },
        { label: 'Open disputes', value: data.disputesOpen },
        { label: 'Notifications that failed (24 hours)', value: data.notificationsFailed24h, bad: data.notificationsFailed24h > 0 },
      ]
    : [];

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} refreshControl={<RefreshControl refreshing={false} onRefresh={load} />}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {data ? (
        <>
          <Text style={styles.small}>Checked {new Date(data.checkedAt).toLocaleString()}. Pull down to refresh.</Text>
          <View style={styles.grid}>
            {tiles.map((t) => (
              <View key={t.label} style={[styles.tile, t.bad ? styles.tileBad : null]}>
                <Text style={styles.value}>{t.value}</Text>
                <Text style={styles.label}>{t.label}</Text>
              </View>
            ))}
          </View>
          <SectionTitle>Most common crashes</SectionTitle>
          {data.topErrors.length === 0 ? <Text style={styles.small}>No crashes reported in the last 24 hours.</Text> : null}
          {data.topErrors.map((e) => (
            <View key={`${e.message}|${e.route}|${e.platform}`} style={styles.error}>
              <Text style={styles.errorTitle}>{e.total} × {e.message}</Text>
              <Text style={styles.small}>{e.platform}{e.route ? ` · ${e.route}` : ''} · last {new Date(e.lastSeen).toLocaleString()}</Text>
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
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  tile: { width: '48%', backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 4 },
  tileBad: { borderColor: colors.danger },
  value: { fontSize: 26, fontWeight: '800', color: colors.text },
  label: { fontSize: 12, color: colors.muted },
  error: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 4 },
  errorTitle: { fontSize: 14, fontWeight: '600', color: colors.text },
  small: { fontSize: 12, color: colors.muted, lineHeight: 18 },
});
