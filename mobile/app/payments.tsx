import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text } from 'react-native';

import { Notice } from '../src/components/ui';
import { formatKwacha } from '../src/domain/money';
import { methodLabel, statusLabel } from '../src/domain/payments';
import { fetchMyPayments, type MyPayment } from '../src/features/payments/api';
import { friendlyError } from '../src/lib/errors';
import { colors, radius, spacing } from '../src/theme';

export default function PaymentHistoryScreen() {
  const router = useRouter();
  const [items, setItems] = useState<MyPayment[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState('');

  useFocusEffect(
    useCallback(() => {
      fetchMyPayments()
        .then((r) => { setItems(r); setError(''); })
        .catch((e) => setError(friendlyError(e)))
        .finally(() => setLoaded(true));
    }, []),
  );

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {loaded && items.length === 0 ? <Text style={styles.empty}>No payments yet.</Text> : null}
      {items.map((p) => (
        <Pressable key={p.id} style={styles.card} onPress={() => router.push(`/order/${p.orderId}`)} accessibilityRole="button">
          <Text style={styles.title}>
            {p.direction === 'paid' ? 'You paid' : 'You received'} {formatKwacha(p.amount)}
          </Text>
          <Text style={styles.meta}>
            {p.orderRef} · {methodLabel(p.method)} · {statusLabel(p.status)}
          </Text>
          {p.refunded > 0 ? <Text style={styles.meta}>Refunded {formatKwacha(p.refunded)}</Text> : null}
          <Text style={styles.meta}>{p.createdAt.slice(0, 10)} · {p.ref}</Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  empty: { color: colors.muted, textAlign: 'center', marginTop: spacing.xl },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: 4, borderWidth: 1, borderColor: colors.border },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
});
