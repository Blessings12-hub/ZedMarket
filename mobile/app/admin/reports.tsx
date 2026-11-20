import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import { Notice } from '../../src/components/ui';
import { fetchOpenReports, type ReportRow, type ReportTarget } from '../../src/features/admin/api';
import { REPORT_REASONS } from '../../src/features/reports/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

const TARGET_LABELS: Record<ReportTarget, string> = {
  listing: 'Listing',
  user: 'Person',
  message: 'Message',
  business: 'Business',
  review: 'Review',
};

function reasonLabel(value: string): string {
  return REPORT_REASONS.find((r) => r.value === value)?.label ?? value;
}

export default function ReportQueue() {
  const router = useRouter();
  const [items, setItems] = useState<ReportRow[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      setItems(await fetchOpenReports());
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
        keyExtractor={(r) => r.id}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, flexGrow: 1 }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>No open reports.</Text>}
        renderItem={({ item }) => (
          <Pressable accessibilityRole="button" style={styles.card} onPress={() => router.push(`/admin/report/${item.id}`)}>
            <Text style={styles.kind}>
              {TARGET_LABELS[item.targetType]} · {item.status === 'in_review' ? 'In review' : 'Open'}
            </Text>
            <Text style={styles.title}>{reasonLabel(item.reason)}</Text>
            {item.details ? (
              <Text style={styles.details} numberOfLines={2}>
                {item.details}
              </Text>
            ) : null}
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
  kind: { fontSize: 13, color: colors.muted },
  title: { fontSize: 17, fontWeight: '600', color: colors.text },
  details: { fontSize: 14, color: colors.text, lineHeight: 20 },
  meta: { fontSize: 12, color: colors.muted },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
