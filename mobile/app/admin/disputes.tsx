import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import { Notice } from '../../src/components/ui';
import { fetchOpenDisputes, type StaffDispute } from '../../src/features/admin/api';
import { DISPUTE_STATUS_LABELS } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function DisputeQueue() {
  const router = useRouter();
  const [items, setItems] = useState<StaffDispute[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      setItems(await fetchOpenDisputes());
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

  return (
    <View style={styles.screen}>
      {error ? (
        <View style={{ padding: spacing.lg }}>
          <Notice tone="error">{error}</Notice>
        </View>
      ) : null}
      <FlatList
        data={items}
        keyExtractor={(d) => d.id}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, flexGrow: 1 }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>No open disputes.</Text>}
        renderItem={({ item }) => (
          <Pressable accessibilityRole="button" style={styles.card} onPress={() => router.push(`/admin/dispute/${item.id}`)}>
            <Text style={styles.meta}>
              {item.orderRef} · {DISPUTE_STATUS_LABELS[item.status]}
            </Text>
            <Text style={styles.title}>{item.reason}</Text>
            <Text style={styles.meta}>{new Date(item.createdAt).toLocaleString()}</Text>
          </Pressable>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  title: { fontSize: 17, fontWeight: '600', color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
