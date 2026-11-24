import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Alert, ScrollView, Share, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { SharePickup } from '../../src/components/SharePickup';
import { Button, Field, Notice, SectionTitle } from '../../src/components/ui';
import { canStartPayment, statusLabel } from '../../src/domain/payments';
import { fetchMyPayments, paymentsEnabled, type MyPayment } from '../../src/features/payments/api';
import { formatKwacha } from '../../src/domain/money';
import {
  actionLabel,
  availableActions,
  canReview,
  eventText,
  expiryText,
  orderPhase,
  parseDeliveryFee,
  phaseLabel,
  receiptText,
  type OrderAction,
  type Receipt,
} from '../../src/domain/orders';
import {
  cancelOrder,
  completeOrder,
  confirmOrder,
  declineOrder,
  fetchOrder,
  fetchOrderEvents,
  fetchReceipt,
  markHandedOver,
  type Order,
  type OrderEvent,
} from '../../src/features/orders/api';
import { fetchDisputeForOrder, fetchReviewedOrderIds } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function OrderScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const { userId } = useAuth();

  const [order, setOrder] = useState<Order | null>(null);
  const [events, setEvents] = useState<OrderEvent[]>([]);
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [reviewed, setReviewed] = useState(false);
  const [orderPayments, setOrderPayments] = useState<MyPayment[]>([]);
  const [payOn, setPayOn] = useState(false);
  const [fee, setFee] = useState('');
  const [reason, setReason] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const o = await fetchOrder(id);
      setOrder(o);
      const [ev, done, rc] = await Promise.all([
        fetchOrderEvents(id).catch(() => [] as OrderEvent[]),
        userId ? fetchReviewedOrderIds(userId).catch(() => new Set<string>()) : Promise.resolve(new Set<string>()),
        o.completedAt ? fetchReceipt(id).catch(() => null) : Promise.resolve(null),
      ]);
      setEvents(ev);
      setReviewed(done.has(id));
      setReceipt(rc);
      setOrderPayments(await fetchMyPayments(id).catch(() => [] as MyPayment[]));
      setPayOn(await paymentsEnabled().catch(() => false));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoading(false);
    }
  }, [id, userId]);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator color={colors.primary} />
      </View>
    );
  }
  if (!order) {
    return (
      <View style={styles.center}>
        <Notice tone="error">{error || 'This order is not available.'}</Notice>
      </View>
    );
  }

  const role = order.buyerId === userId ? 'buyer' : 'seller';
  const phase = orderPhase(order);
  const actions = availableActions(role, phase);
  const countdown = ['requested', 'confirmed'].includes(phase) ? expiryText(order.expiresAt) : null;

  async function run(action: OrderAction) {
    if (!order) return;
    if (action === 'dispute') {
      router.push({ pathname: '/dispute/open', params: { orderId: order.id } });
      return;
    }
    let feeAmount = 0;
    if (action === 'confirm' && order.fulfilment === 'delivery') {
      const parsed = parseDeliveryFee(fee);
      if ('error' in parsed) {
        setError(parsed.error);
        return;
      }
      feeAmount = parsed.fee;
    }
    setBusy(true);
    setError('');
    try {
      if (action === 'confirm') await confirmOrder(order.id, feeAmount);
      else if (action === 'decline') await declineOrder(order.id, reason);
      else if (action === 'cancel') await cancelOrder(order.id, reason);
      else if (action === 'handover') await markHandedOver(order.id);
      else if (action === 'complete') await completeOrder(order.id);
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  function ask(action: OrderAction) {
    if (action === 'cancel' || action === 'decline' || action === 'complete') {
      const text =
        action === 'complete'
          ? 'Only confirm if you have the item and are happy with it.'
          : action === 'decline'
            ? 'The buyer will be told the order was declined.'
            : 'The other person will see that the order was cancelled.';
      Alert.alert(`${actionLabel(action, order!.fulfilment)}?`, text, [
        { text: 'Go back', style: 'cancel' },
        { text: 'Yes', style: action === 'complete' ? 'default' : 'destructive', onPress: () => run(action) },
      ]);
      return;
    }
    void run(action);
  }

  async function openDisputeCase() {
    try {
      const dispute = await fetchDisputeForOrder(order!.id);
      if (dispute) router.push(`/dispute/${dispute.id}`);
      else Alert.alert('No dispute found', 'This order is marked as in dispute but we could not find the case.');
    } catch (e) {
      Alert.alert('Could not open the dispute', friendlyError(e));
    }
  }

  async function shareReceipt() {
    if (!receipt) return;
    try {
      await Share.share({ message: receiptText(receipt) });
    } catch {
      // Closing the share sheet is not an error.
    }
  }

  const paidInApp = orderPayments.some((p) => p.status === 'succeeded');
  const needsReason = actions.includes('decline') || actions.includes('cancel');

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      <View style={styles.card}>
        <Text style={styles.ref}>
          {order.ref} · {role === 'buyer' ? `Buying from ${order.sellerName}` : `Selling to ${order.buyerName}`}
        </Text>
        <Text style={styles.title}>{order.title}</Text>
        <Text style={styles.status}>{phaseLabel(phase, role, order.fulfilment)}</Text>
        {countdown ? <Text style={styles.meta}>{countdown}</Text> : null}
        {order.cancelledReason && order.status === 'cancelled' ? <Text style={styles.meta}>Reason: {order.cancelledReason}</Text> : null}
      </View>

      <View style={styles.card}>
        <Text style={styles.line}>Item {formatKwacha(order.price)}</Text>
        {order.fulfilment === 'delivery' ? (
          <Text style={styles.line}>
            Delivery fee {order.confirmedAt || order.deliveryFee > 0 ? formatKwacha(order.deliveryFee) : 'to be set by the seller'}
          </Text>
        ) : null}
        <Text style={styles.total}>Total agreed {formatKwacha(order.total)}</Text>
        <Text style={styles.meta}>
          {order.fulfilment === 'delivery' ? `Delivery to: ${order.deliveryAddress}` : 'Collection: you arrange the meeting with the seller'}
        </Text>
        {order.fulfilment === 'collection' && order.pickupText ? <Text style={styles.meta}>Pickup address: {order.pickupText}</Text> : null}
        {order.buyerNote ? <Text style={styles.meta}>Buyer's note: {order.buyerNote}</Text> : null}
        <Text style={styles.meta}>
          {paidInApp
            ? 'Paid through ZedMarket by mobile money. ZedMarket does not hold the money.'
            : 'You pay the seller directly unless paying in the app is offered below. ZedMarket does not hold payment.'}
        </Text>
      </View>
      {role === 'buyer' && payOn && canStartPayment(order.status, 'buyer', orderPayments) ? (
        <Button title="Pay with mobile money" onPress={() => router.push(`/pay/${order.id}`)} />
      ) : null}
      {role === 'seller' && order.fulfilment === 'collection' && order.status === 'confirmed' ? <SharePickup orderId={order.id} onDone={load} /> : null}
      <Button title="Problem with this order? Ask for help" variant="secondary" onPress={() => router.push(`/support/new?orderId=${order.id}`)} />
      {orderPayments[0] ? (
        <View style={styles.card}>
          <Text style={styles.line}>Payment: {statusLabel(orderPayments[0].status)}</Text>
        </View>
      ) : null}

      {error ? <Notice tone="error">{error}</Notice> : null}

      {actions.includes('confirm') && order.fulfilment === 'delivery' ? (
        <Field
          label="Delivery fee in kwacha (leave empty if free)"
          value={fee}
          onChangeText={setFee}
          keyboardType="decimal-pad"
          placeholder="For example 50"
        />
      ) : null}
      {needsReason ? <Field label="Reason (optional)" value={reason} onChangeText={setReason} maxLength={300} /> : null}

      {actions.filter((a) => a !== 'dispute').map((a) => (
        <Button
          key={a}
          title={actionLabel(a, order.fulfilment)}
          variant={a === 'decline' || a === 'cancel' ? 'secondary' : 'primary'}
          onPress={() => ask(a)}
          loading={busy}
          disabled={busy}
        />
      ))}
      {canReview(phase, reviewed) ? <Button title="Leave a review" onPress={() => router.push(`/review/${order.id}`)} /> : null}
      {actions.includes('dispute') ? <Button title={actionLabel('dispute', order.fulfilment)} variant="secondary" onPress={() => run('dispute')} /> : null}
      {phase === 'disputed' ? <Button title="See the dispute" variant="secondary" onPress={openDisputeCase} /> : null}
      <Button title="View listing" variant="secondary" onPress={() => router.push(`/listing/${order.listingId}`)} />

      <SectionTitle>History</SectionTitle>
      <View style={styles.card}>
        {events.length === 0 ? <Text style={styles.meta}>No history yet.</Text> : null}
        {events.map((e) => (
          <View key={e.id} style={styles.event}>
            <Text style={styles.line}>{eventText(e.event, e.actorRole, order.fulfilment)}</Text>
            {e.note ? <Text style={styles.meta}>{e.note}</Text> : null}
            <Text style={styles.meta}>{new Date(e.createdAt).toLocaleString('en-ZM')}</Text>
          </View>
        ))}
      </View>

      {receipt ? (
        <>
          <SectionTitle>Receipt</SectionTitle>
          <View style={styles.card}>
            <Text style={styles.line}>{receiptText(receipt)}</Text>
          </View>
          <Button title="Share receipt" variant="secondary" onPress={shareReceipt} />
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  ref: { fontSize: 13, color: colors.muted },
  title: { fontSize: 18, fontWeight: '700', color: colors.text },
  status: { fontSize: 15, fontWeight: '600', color: colors.primary },
  line: { fontSize: 15, color: colors.text },
  total: { fontSize: 18, fontWeight: '700', color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
  event: { paddingVertical: spacing.xs, gap: 2 },
});
