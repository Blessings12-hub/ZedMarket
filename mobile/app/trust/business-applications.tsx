import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Notice } from '../../src/components/ui';
import * as api from '../../src/features/business-onboarding/api';
import { QUEUES, STATUS_LABEL, type AppStatus, type QueueKey } from '../../src/features/seller-onboarding/domain';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

// Business verification queues for support officers. The database refuses anyone without a support role and two-factor.
export default function BusinessApplications() {
  const router = useRouter();
  const [queue, setQueue] = useState<QueueKey>('sellers');
  const [rows, setRows] = useState<api.BizQueueRow[] | null>(null);
  const [error, setError] = useState('');

  const load = useCallback(async (q: QueueKey) => {
    setRows(null);
    try {
      const r = await api.fetchQueue(q);
      setRows(Array.isArray(r) ? r : []);
      setError('');
    } catch (e) {
      console.error('[trust] business queue failed', e);
      setError(friendlyError(e));
      setRows([]);
    }
  }, []);
  useFocusEffect(useCallback(() => { void load(queue); }, [load, queue]));

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <View style={styles.chips}>
        {QUEUES.map((q) => <Chip key={q.key} label={q.key === 'sellers' ? 'Business applications' : q.label} selected={queue === q.key} onPress={() => setQueue(q.key)} />)}
      </View>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {error ? <Button title="Try again" variant="secondary" onPress={() => void load(queue)} /> : null}
      {rows === null ? <ActivityIndicator color={colors.primary} /> : null}
      {rows?.length === 0 && !error ? <Text style={styles.text}>Nothing in this queue.</Text> : null}
      {rows?.map((r) => (
        <Pressable key={r.id} style={styles.card} onPress={() => router.push({ pathname: '/trust/business-application/[id]', params: { id: r.id } })}>
          <Text style={styles.title}>{r.business_name}</Text>
          <Text style={styles.text}>
            {r.route === 'informal_trader' ? 'Informal trader' : 'Registered business'} · {r.applicant_name}
          </Text>
          <Text style={styles.text}>
            {STATUS_LABEL[r.status as AppStatus] ?? r.status}
            {r.risk_level === 'high' ? ' · higher risk' : ''}{r.escalated ? ' · escalated' : ''}{r.awaiting_second ? ' · needs second officer' : ''}
          </Text>
          <Text style={styles.text}>
            {r.assigned_name ? `With ${r.mine ? 'you' : r.assigned_name}` : 'Unassigned'} · {r.pending_documents} document(s) to check{r.overdue ? ' · OVERDUE' : ''}
          </Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 4 },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  text: { fontSize: 13, color: colors.muted },
});
