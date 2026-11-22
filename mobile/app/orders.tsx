import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../src/auth/AuthProvider';
import { Chip, Notice } from '../src/components/ui';
import { formatKwacha } from '../src/domain/money';
import { availableActions, expiryText, orderPhase, phaseLabel } from '../src/domain/orders';
import { listOrders, type Order } from '../src/features/orders/api';
import { friendlyError } from '../src/lib/errors';
import { colors, radius, spacing } from '../src/theme';

type Filter = 'all' | 'buying' | 'selling';

// The list shows where each order stands and what needs you. Everything you can do is on the order itself.
export default function OrdersScreen() {
  const router = useRouter();
  const { userId } = useAuth();
  const [orders, setOrders] = useState<Order[]>([]);
  const [filter, setFilter] = useState<Filter>('all');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      setOrders(await listOrders());
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  const shown = orders.filter((o) => (filter === 'all' ? true : filter === 'buying' ? o.buyerId === userId : o.buyerId !== userId));

  return (
    <View style={styles.screen}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ flexGrow: 0 }} contentContainerStyle={styles.filters}>
        <Chip label="All" selected={filter === 'all'} onPress={() => setFilter('all')} />
        <Chip label="Buying" selected={filter === 'buying'} onPress={() => setFilter('buying')} />
        <Chip label="Selling" selected={filter === 'selling'} onPress={() => setFilter('selling')} />
      </ScrollView>

      {error ? (
        <View style={{ padding: spacing.lg }}>
          <Notice tone="error">{error}</Notice>
        </View>
      ) : null}

      <FlatList
        data={shown}
        keyExtractor={(o) => o.id}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, flexGrow: 1 }}
        ListEmptyComponent={
          loading ? null : (
            <View style={styles.empty}>
              <Text style={styles.emptyTitle}>No orders here</Text>
              <Text style={styles.emptyText}>When you ask to buy something, or someone asks to buy from you, it appears here.</Text>
            </View>
          )
        }
        renderItem={({ item }) => {
          const role = item.buyerId === userId ? 'buyer' : 'seller';
          const phase = orderPhase(item);
          const needsYou = availableActions(role, phase).some((a) => a !== 'dispute' && a !== 'cancel');
          const countdown = phase === 'requested' || phase === 'confirmed' ? expiryText(item.expiresAt) : null;
          return (
            <Pressable accessibilityRole="button" style={[styles.card, needsYou && styles.needsYou]} onPress={() => router.push(`/order/${item.id}`)}>
              <Text style={styles.ref}>
                {item.ref} · {role === 'buyer' ? 'You are buying' : 'You are selling'}
              </Text>
              <Text style={styles.title}>{item.title}</Text>
              <Text style={styles.price}>{formatKwacha(item.total)}</Text>
              <Text style={styles.status}>{phaseLabel(phase, role, item.fulfilment)}</Text>
              {countdown ? <Text style={styles.meta}>{countdown}</Text> : null}
            </Pressable>
          );
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  filters: { gap: spacing.sm, padding: spacing.lg, paddingBottom: spacing.sm },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  needsYou: { borderColor: colors.primary, borderWidth: 2 },
  ref: { fontSize: 13, color: colors.muted },
  title: { fontSize: 17, fontWeight: '600', color: colors.text },
  price: { fontSize: 20, fontWeight: '700', color: colors.text },
  status: { fontSize: 14, color: colors.primary, fontWeight: '600' },
  meta: { fontSize: 13, color: colors.muted },
  empty: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: spacing.xs },
  emptyTitle: { fontSize: 18, fontWeight: '600', color: colors.text },
  emptyText: { color: colors.muted, textAlign: 'center' },
});
