import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Notice } from '../../../../src/components/ui';
import { formatKwacha } from '../../../../src/domain/money';
import { fetchBusinessOrders, type BusinessOrder } from '../../../../src/features/business/api';
import { friendlyError } from '../../../../src/lib/errors';
import { colors, radius, spacing } from '../../../../src/theme';

const FILTERS: Array<{ label: string; value: BusinessOrder['status'] | null }> = [
  { label: 'All', value: null },
  { label: 'Requests', value: 'requested' },
  { label: 'Confirmed', value: 'confirmed' },
  { label: 'Completed', value: 'completed' },
  { label: 'Cancelled', value: 'cancelled' },
  { label: 'Disputed', value: 'disputed' },
];

export default function BusinessOrders() {
  const router = useRouter();
  const { id } = useLocalSearchParams<{ id: string }>();
  const [status, setStatus] = useState<BusinessOrder['status'] | null>(null);
  const [items, setItems] = useState<BusinessOrder[]>([]);
  const [more, setMore] = useState(false);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(
    async (offset = 0) => {
      if (!id) return;
      try {
        const page = await fetchBusinessOrders(id, status, offset);
        setItems((cur) => (offset === 0 ? page : [...cur, ...page]));
        setMore(page.length === 30);
        setError('');
      } catch (e) {
        setError(friendlyError(e));
      } finally {
        setLoading(false);
      }
    },
    [id, status],
  );

  useFocusEffect(
    useCallback(() => {
      setLoading(true);
      load(0);
    }, [load]),
  );

  return (
    <View style={styles.screen}>
      <View style={styles.filters}>
        {FILTERS.map((f) => (
          <Chip key={f.label} label={f.label} selected={status === f.value} onPress={() => setStatus(f.value)} />
        ))}
      </View>
      {error ? <View style={{ paddingHorizontal: spacing.lg }}><Notice tone="error">{error}</Notice></View> : null}
      <FlatList
        data={items}
        keyExtractor={(o) => o.id}
        refreshing={loading}
        onRefresh={() => load(0)}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.sm, flexGrow: 1 }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>No orders here.</Text>}
        ListFooterComponent={more ? <Button title="Load more" variant="secondary" onPress={() => load(items.length)} /> : null}
        renderItem={({ item }) => (
          <Pressable accessibilityRole="button" style={styles.card} onPress={() => router.push({ pathname: '/order/[id]', params: { id: item.id } })}>
            <Text style={styles.title}>{item.itemTitle}</Text>
            <Text style={styles.text}>{formatKwacha(item.price)} · {item.buyerName}</Text>
            <Text style={styles.meta}>
              {item.status} · {item.fulfilment}{item.branchName ? ` · ${item.branchName}` : ''} · {new Date(item.createdAt).toLocaleDateString()}
            </Text>
            {item.status === 'requested' ? <Text style={styles.action}>Waiting for you. Tap to answer.</Text> : null}
          </Pressable>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  filters: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm, padding: spacing.lg },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: 2 },
  title: { fontSize: 16, fontWeight: '600', color: colors.text },
  text: { fontSize: 14, color: colors.text },
  meta: { fontSize: 12, color: colors.muted, textTransform: 'capitalize' },
  action: { fontSize: 13, color: colors.primary, fontWeight: '600', marginTop: 4 },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
