import { useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Field, Notice } from '../../src/components/ui';
import { formatKwacha } from '../../src/domain/money';
import { METHODS, newPaymentKey, normalisePhone, statusLabel, type PaymentMethod } from '../../src/domain/payments';
import { cancelPayment, fetchMyPayments, paymentsEnabled, startPayment, type MyPayment } from '../../src/features/payments/api';
import { fetchOrder } from '../../src/features/orders/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

// Paying through ZedMarket records a mobile-money payment made via an authorised provider. The result
// comes from the provider, never from this screen: it only asks and then shows what the server says.
export default function PayScreen() {
  const { orderId } = useLocalSearchParams<{ orderId: string }>();
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [total, setTotal] = useState<number | null>(null);
  const [method, setMethod] = useState<PaymentMethod>('mtn_momo');
  const [phone, setPhone] = useState('');
  const [payments, setPayments] = useState<MyPayment[]>([]);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const key = useRef(newPaymentKey());

  const load = useCallback(async () => {
    if (!orderId) return;
    try {
      const [on, order, list] = await Promise.all([paymentsEnabled(), fetchOrder(orderId), fetchMyPayments(orderId)]);
      setEnabled(on);
      setTotal(order.total);
      setPayments(list);
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [orderId]);

  useEffect(() => {
    void load();
  }, [load]);

  const latest = payments[0];
  const waiting = latest?.status === 'pending';

  // While a payment waits, ask the server every few seconds what the provider said.
  useEffect(() => {
    if (!waiting) return undefined;
    const t = setInterval(() => void load(), 5000);
    return () => clearInterval(t);
  }, [waiting, load]);

  async function pay() {
    const normal = normalisePhone(phone);
    if (!normal) {
      setError('Enter the mobile money number, for example 0961234567.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      await startPayment(orderId!, method, normal, key.current);
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  async function cancel() {
    if (!latest) return;
    setBusy(true);
    try {
      await cancelPayment(latest.id);
      key.current = newPaymentKey();
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {enabled === false ? <Notice>Paying through ZedMarket is not switched on yet. Pay the seller as you agreed.</Notice> : null}

      {total !== null ? <Text style={styles.total}>Amount: {formatKwacha(total)}</Text> : null}

      {latest ? (
        <View style={styles.card}>
          <Text style={styles.status}>{statusLabel(latest.status)}</Text>
          {waiting ? (
            <Text style={styles.meta}>Approve the payment on your phone when the prompt appears. This page updates by itself.</Text>
          ) : null}
          {latest.status === 'failed' && latest.failureReason ? <Text style={styles.meta}>{latest.failureReason}</Text> : null}
          {latest.status === 'succeeded' ? <Text style={styles.meta}>Reference {latest.ref}. Keep it if you ever need help.</Text> : null}
          {waiting ? <Button title="Cancel this payment" variant="secondary" onPress={cancel} loading={busy} /> : null}
        </View>
      ) : null}

      {enabled && latest?.status !== 'pending' && latest?.status !== 'succeeded' ? (
        <>
          <View style={styles.row}>
            {METHODS.map((m) => (
              <Chip key={m.key} label={m.label} selected={method === m.key} onPress={() => setMethod(m.key)} />
            ))}
          </View>
          <Field label="Mobile money number" value={phone} onChangeText={setPhone} keyboardType="phone-pad" placeholder="0961234567" />
          <Button title={`Pay ${total !== null ? formatKwacha(total) : ''}`} onPress={pay} loading={busy} />
          <Text style={styles.meta}>
            ZedMarket does not hold your money. The payment goes through your mobile money provider and we record the result.
          </Text>
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  total: { fontSize: 22, fontWeight: '700', color: colors.text },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: spacing.sm, borderWidth: 1, borderColor: colors.border },
  status: { fontSize: 16, fontWeight: '700', color: colors.primary },
  meta: { fontSize: 13, color: colors.muted, lineHeight: 19 },
  row: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' },
});
