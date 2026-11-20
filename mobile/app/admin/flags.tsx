import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';

import { Button, Notice } from '../../src/components/ui';
import { fetchOpenFlags, markFlagReviewed, type RiskFlag } from '../../src/features/admin/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

const SIGNAL_LABELS: Record<string, string> = {
  repeated_reports: 'Reported by several different people',
};

export default function RiskFlags() {
  const router = useRouter();
  const [items, setItems] = useState<RiskFlag[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setItems(await fetchOpenFlags());
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  async function done(flag: RiskFlag) {
    setBusyId(flag.id);
    try {
      await markFlagReviewed(flag.id);
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <View style={styles.screen}>
      <View style={{ padding: spacing.lg, gap: spacing.sm }}>
        <Notice>A flag is only a reason to take a look. It never blocks anyone by itself.</Notice>
        {error ? <Notice tone="error">{error}</Notice> : null}
      </View>
      <FlatList
        data={items}
        keyExtractor={(f) => f.id}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ paddingHorizontal: spacing.lg, paddingBottom: spacing.lg, gap: spacing.md, flexGrow: 1 }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>No open flags.</Text>}
        renderItem={({ item }) => (
          <View style={styles.card}>
            <Text style={styles.title}>{SIGNAL_LABELS[item.signal] ?? item.signal.replace(/_/g, ' ')}</Text>
            <Text style={styles.meta}>
              {item.subjectType} · {new Date(item.createdAt).toLocaleString()}
            </Text>
            {Object.keys(item.detail).length > 0 ? <Text style={styles.meta}>{JSON.stringify(item.detail)}</Text> : null}
            {item.subjectType === 'listing' ? (
              <Button title="Open the listing" variant="secondary" onPress={() => router.push(`/listing/${item.subjectId}`)} />
            ) : null}
            <Button title="Mark as looked at" onPress={() => done(item)} loading={busyId === item.id} />
          </View>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  title: { fontSize: 17, fontWeight: '600', color: colors.text, textTransform: 'capitalize' },
  meta: { fontSize: 13, color: colors.muted },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
