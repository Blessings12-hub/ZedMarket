import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';

import { Notice } from '../../src/components/ui';
import { fetchAudit, type AuditEntry } from '../../src/features/admin/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function AuditLog() {
  const [items, setItems] = useState<AuditEntry[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      setItems(await fetchAudit());
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
      <View style={{ padding: spacing.lg, gap: spacing.sm }}>
        <Notice>The latest 100 actions taken by staff and by the system. This list cannot be edited.</Notice>
        {error ? <Notice tone="error">{error}</Notice> : null}
      </View>
      <FlatList
        data={items}
        keyExtractor={(a) => String(a.id)}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ paddingHorizontal: spacing.lg, paddingBottom: spacing.lg, gap: spacing.sm }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>Nothing recorded yet.</Text>}
        renderItem={({ item }) => (
          <View style={styles.row}>
            <Text style={styles.action}>{item.action}</Text>
            <Text style={styles.meta}>
              {item.targetType ? `${item.targetType} ${item.targetId ?? ''}` : 'no target'}
            </Text>
            <Text style={styles.meta}>
              by {item.actorId ? item.actorId.slice(0, 8) : 'system'} · {new Date(item.createdAt).toLocaleString()}
            </Text>
          </View>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  row: { backgroundColor: colors.surface, borderRadius: radius.sm, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 2 },
  action: { fontSize: 15, fontWeight: '600', color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
