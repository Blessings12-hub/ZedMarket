import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Notice } from '../../src/components/ui';
import { fetchPerformance, type AgentRow } from '../../src/features/support/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function PerformanceScreen() {
  const [rows, setRows] = useState<AgentRow[]>([]);
  const [error, setError] = useState('');
  useFocusEffect(
    useCallback(() => {
      fetchPerformance(30).then((r) => { setRows(r); setError(''); }).catch((e) => setError(friendlyError(e)));
    }, []),
  );
  const show = (v: number | null, unit = '') => (v === null ? 'no data' : `${v}${unit}`);
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.meta}>Last 30 days. Team leads see everyone; everyone else sees only their own row. These figures are a guide for coaching, not a score to chase.</Text>
      {rows.map((r) => (
        <View key={r.id} style={styles.card}>
          <Text style={styles.title}>{r.name}</Text>
          <Text style={styles.meta}>Resolved: {r.resolved}</Text>
          <Text style={styles.meta}>Average first reply: {show(r.firstResponse, ' min')}</Text>
          <Text style={styles.meta}>Average time to resolve: {show(r.resolution, ' h')}</Text>
          <Text style={styles.meta}>Average rating: {show(r.rating, ' / 5')}</Text>
          <Text style={styles.meta}>Open now: {r.openNow} · Late for a first reply: {r.overdueNow}</Text>
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: 4, borderWidth: 1, borderColor: colors.border },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  meta: { fontSize: 13, color: colors.muted, lineHeight: 19 },
});
