import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, Image, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice } from '../../src/components/ui';
import { reasonProblem } from '../../src/domain/admin';
import { conditionLabel } from '../../src/domain/listing';
import { formatKwacha } from '../../src/domain/money';
import { approveListing, fetchPendingListings, rejectListing, type QueuedListing } from '../../src/features/admin/api';
import { friendlyError } from '../../src/lib/errors';
import { listingImageUrl } from '../../src/lib/supabase';
import { colors, radius, spacing } from '../../src/theme';

export default function ListingQueue() {
  const [items, setItems] = useState<QueuedListing[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [rejectingId, setRejectingId] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setItems(await fetchPendingListings());
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

  async function approve(item: QueuedListing) {
    setBusyId(item.id);
    setError('');
    try {
      await approveListing(item.id, '');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusyId(null);
    }
  }

  async function reject(item: QueuedListing) {
    const problem = reasonProblem(reason);
    if (problem) {
      setError(problem);
      return;
    }
    setBusyId(item.id);
    setError('');
    try {
      // The seller sees this note, so it has to be something they can act on.
      await rejectListing(item.id, reason);
      setRejectingId(null);
      setReason('');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <View style={styles.screen}>
      {error ? (
        <View style={{ padding: spacing.lg }}>
          <Notice tone="error">{error}</Notice>
        </View>
      ) : null}
      <FlatList
        data={items}
        keyExtractor={(i) => i.id}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, flexGrow: 1 }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>Nothing is waiting for review.</Text>}
        renderItem={({ item }) => {
          const busy = busyId === item.id;
          const rejecting = rejectingId === item.id;
          return (
            <View style={styles.card}>
              {item.imagePaths.length > 0 ? (
                <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: spacing.sm }}>
                  {item.imagePaths.map((path) => (
                    <Image key={path} source={{ uri: listingImageUrl(path) }} style={styles.photo} />
                  ))}
                </ScrollView>
              ) : null}

              <Text style={styles.title}>{item.title}</Text>
              <Text style={styles.price}>
                {formatKwacha(item.price)} · {conditionLabel(item.condition)}
              </Text>
              <Text style={styles.meta}>
                Seller: {item.sellerName}
                {item.sellerState !== 'active' ? ` (${item.sellerState})` : ''}
              </Text>
              {item.note ? <Notice tone="warning">{item.note}</Notice> : null}

              {rejecting ? (
                <>
                  <Field
                    label="Why is it being turned down? The seller will see this."
                    value={reason}
                    onChangeText={setReason}
                    multiline
                    maxLength={500}
                    style={{ minHeight: 80, textAlignVertical: 'top' }}
                  />
                  <Button title="Turn down listing" variant="danger" onPress={() => reject(item)} loading={busy} />
                  <Button
                    title="Back"
                    variant="secondary"
                    onPress={() => {
                      setRejectingId(null);
                      setReason('');
                      setError('');
                    }}
                    disabled={busy}
                  />
                </>
              ) : (
                <>
                  <Button title="Approve" onPress={() => approve(item)} loading={busy} />
                  <Button
                    title="Turn down"
                    variant="secondary"
                    onPress={() => {
                      setRejectingId(item.id);
                      setReason('');
                      setError('');
                    }}
                    disabled={busy}
                  />
                </>
              )}
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
  photo: { width: 160, height: 160, borderRadius: radius.sm, backgroundColor: colors.primarySoft },
  title: { fontSize: 17, fontWeight: '600', color: colors.text },
  price: { fontSize: 16, fontWeight: '700', color: colors.text },
  meta: { fontSize: 14, color: colors.muted },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
