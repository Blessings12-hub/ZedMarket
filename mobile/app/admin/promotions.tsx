import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, FlatList, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice } from '../../src/components/ui';
import { formatKwacha } from '../../src/domain/money';
import { decisionError, type QueuedPromotion } from '../../src/domain/promotion';
import { decidePromotion, fetchPromotionQueue } from '../../src/features/promotion/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

// Staff: approve a promotion only after the seller has paid. Type the payment reference (for example the mobile money code).
export default function Promotions() {
  const router = useRouter();
  const [items, setItems] = useState<QueuedPromotion[]>([]);
  const [notes, setNotes] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    try {
      setItems(await fetchPromotionQueue());
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useFocusEffect(useCallback(() => { void load(); }, [load]));

  async function decide(item: QueuedPromotion, approve: boolean) {
    const note = notes[item.id] ?? '';
    const problem = decisionError(approve, note);
    if (problem) { setError(problem); return; }
    setBusyId(item.id);
    setError('');
    try {
      await decidePromotion(item.id, approve, note);
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusyId(null);
    }
  }

  if (loading) return <ActivityIndicator style={{ marginTop: spacing.xl }} color={colors.primary} />;

  return (
    <FlatList
      style={{ backgroundColor: colors.background }}
      contentContainerStyle={styles.content}
      data={items}
      keyExtractor={(i) => i.id}
      ListHeaderComponent={error ? <Notice tone="error">{error}</Notice> : <Notice>Approve only after the seller has paid. The text box is the payment reference when approving, or the reason when rejecting.</Notice>}
      ListEmptyComponent={<Text style={styles.meta}>No promotion requests are waiting.</Text>}
      renderItem={({ item }) => (
        <View style={styles.card}>
          <Text style={styles.title}>{item.title}</Text>
          <Text style={styles.meta}>{item.sellerName} · {item.days} days · {formatKwacha(item.price)}</Text>
          <Button title="Open the listing" variant="secondary" onPress={() => router.push(`/listing/${item.listingId}`)} />
          <Field label="Payment reference, or reason to reject" value={notes[item.id] ?? ''} onChangeText={(t) => setNotes((n) => ({ ...n, [item.id]: t }))} maxLength={300} />
          <Button title="Paid: approve" onPress={() => decide(item, true)} loading={busyId === item.id} disabled={busyId !== null} />
          <Button title="Reject" variant="secondary" onPress={() => decide(item, false)} disabled={busyId !== null} />
        </View>
      )}
    />
  );
}

const styles = StyleSheet.create({
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
});
