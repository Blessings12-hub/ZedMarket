import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Alert, FlatList, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../src/auth/AuthProvider';
import { Button, Notice } from '../src/components/ui';
import { formatKwacha } from '../src/domain/money';
import { changeOrderStatus, listOrders, ORDER_STATUS_LABELS, type Order, type OrderStatus } from '../src/features/orders/api';
import { fetchDisputeForOrder, fetchReviewedOrderIds } from '../src/features/trust/api';
import { friendlyError } from '../src/lib/errors';
import { colors, radius, spacing } from '../src/theme';

export default function OrdersScreen() {
  const router = useRouter();
  const { userId } = useAuth();
  const [orders, setOrders] = useState<Order[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [reviewed, setReviewed] = useState<Set<string>>(new Set());

  const load = useCallback(async () => {
    try {
      const [list, done] = await Promise.all([listOrders(), userId ? fetchReviewedOrderIds(userId) : Promise.resolve(new Set<string>())]);
      setOrders(list);
      setReviewed(done);
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoading(false);
    }
  }, [userId]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  async function move(order: Order, status: OrderStatus) {
    setBusyId(order.id);
    try {
      await changeOrderStatus(order.id, status);
      await load();
    } catch (e) {
      Alert.alert('Could not update the order', friendlyError(e));
    } finally {
      setBusyId(null);
    }
  }

  async function openExistingDispute(order: Order) {
    setBusyId(order.id);
    try {
      const dispute = await fetchDisputeForOrder(order.id);
      if (dispute) router.push(`/dispute/${dispute.id}`);
      else Alert.alert('No dispute found', 'This order is marked as in dispute but we could not find the case.');
    } catch (e) {
      Alert.alert('Could not open the dispute', friendlyError(e));
    } finally {
      setBusyId(null);
    }
  }

  function confirmCancel(order: Order) {
    Alert.alert('Cancel this order?', order.ref, [
      { text: 'Keep it', style: 'cancel' },
      { text: 'Cancel order', style: 'destructive', onPress: () => move(order, 'cancelled') },
    ]);
  }

  return (
    <View style={styles.screen}>
      {error ? (
        <View style={{ padding: spacing.lg }}>
          <Notice tone="error">{error}</Notice>
        </View>
      ) : null}

      <FlatList
        data={orders}
        keyExtractor={(o) => o.id}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, flexGrow: 1 }}
        ListEmptyComponent={
          loading ? null : (
            <View style={styles.empty}>
              <Text style={styles.emptyTitle}>No orders yet</Text>
              <Text style={styles.emptyText}>When you ask to buy something, or someone asks to buy from you, it appears here.</Text>
            </View>
          )
        }
        renderItem={({ item }) => {
          const asBuyer = item.buyerId === userId;
          const busy = busyId === item.id;
          return (
            <View style={styles.card}>
              <Text style={styles.ref}>
                {item.ref} · {asBuyer ? 'You are buying' : 'You are selling'}
              </Text>
              <Text style={styles.title}>{item.title}</Text>
              <Text style={styles.price}>{formatKwacha(item.total)}</Text>
              <Text style={styles.status}>{ORDER_STATUS_LABELS[item.status]}</Text>

              {item.status === 'requested' && !asBuyer ? (
                <Button title="Confirm order" onPress={() => move(item, 'confirmed')} loading={busy} />
              ) : null}
              {item.status === 'confirmed' && asBuyer ? (
                <Button title="I have received it" onPress={() => move(item, 'completed')} loading={busy} />
              ) : null}
              {item.status === 'requested' || item.status === 'confirmed' ? (
                <Button title="Cancel order" variant="secondary" onPress={() => confirmCancel(item)} disabled={busy} />
              ) : null}
              {item.status === 'completed' && !reviewed.has(item.id) ? (
                <Button title="Leave a review" onPress={() => router.push(`/review/${item.id}`)} />
              ) : null}
              {item.status === 'confirmed' || item.status === 'completed' ? (
                <Button
                  title="Report a problem"
                  variant="secondary"
                  onPress={() => router.push({ pathname: '/dispute/open', params: { orderId: item.id } })}
                />
              ) : null}
              {item.status === 'disputed' ? (
                <Button title="See the dispute" variant="secondary" onPress={() => openExistingDispute(item)} disabled={busy} />
              ) : null}
              <Button title="View listing" variant="secondary" onPress={() => router.push(`/listing/${item.listingId}`)} />
            </View>
          );
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  ref: { fontSize: 13, color: colors.muted },
  title: { fontSize: 17, fontWeight: '600', color: colors.text },
  price: { fontSize: 20, fontWeight: '700', color: colors.text },
  status: { fontSize: 14, color: colors.primary, fontWeight: '600' },
  empty: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: spacing.xs },
  emptyTitle: { fontSize: 18, fontWeight: '600', color: colors.text },
  emptyText: { color: colors.muted, textAlign: 'center' },
});
