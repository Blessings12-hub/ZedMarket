import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';

import { Button, Notice } from '../../src/components/ui';
import { auditActionLabel, auditDetail } from '../../src/domain/trustAdmin';
import { fetchTrustAudit, type TrustAuditEntry } from '../../src/features/trust-admin/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function TrustAudit() {
  const { userId } = useLocalSearchParams<{ userId?: string }>();
  const [items, setItems] = useState<TrustAuditEntry[]>([]);
  const [more, setMore] = useState(false);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(
    async (offset = 0) => {
      try {
        const page = await fetchTrustAudit(userId ?? null, offset);
        setItems((current) => (offset === 0 ? page : [...current, ...page]));
        setMore(page.length === 50);
        setError('');
      } catch (e) {
        setError(friendlyError(e));
      } finally {
        setLoading(false);
      }
    },
    [userId],
  );

  useFocusEffect(
    useCallback(() => {
      load(0);
    }, [load]),
  );

  return (
    <View style={styles.screen}>
      <View style={{ padding: spacing.lg, gap: spacing.sm }}>
        <Notice>{userId ? 'Everything staff did about this person.' : 'The latest staff actions in this section.'} Entries cannot be edited or deleted.</Notice>
        {error ? <Notice tone="error">{error}</Notice> : null}
      </View>
      <FlatList
        data={items}
        keyExtractor={(a) => String(a.id)}
        refreshing={loading}
        onRefresh={() => load(0)}
        contentContainerStyle={{ paddingHorizontal: spacing.lg, paddingBottom: spacing.lg, gap: spacing.sm }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>Nothing recorded yet.</Text>}
        ListFooterComponent={more ? <Button title="Load more" variant="secondary" onPress={() => load(items.length)} /> : null}
        renderItem={({ item }) => (
          <View style={styles.row}>
            <Text style={styles.action}>{auditActionLabel(item.action)}</Text>
            {auditDetail(item.action, item.metadata) ? <Text style={styles.detail}>{auditDetail(item.action, item.metadata)}</Text> : null}
            <Text style={styles.meta}>
              by {item.actorName ?? 'the system'} · {new Date(item.createdAt).toLocaleString()}
            </Text>
          </View>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  row: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 2 },
  action: { fontSize: 15, fontWeight: '600', color: colors.text },
  detail: { fontSize: 14, color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
