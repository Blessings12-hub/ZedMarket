import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { formatKwacha } from '../../src/domain/money';
import { validateCheckout, type Fulfilment } from '../../src/domain/orders';
import { fetchListing } from '../../src/features/listings/api';
import type { ListingDetail } from '../../src/features/listings/types';
import { isListingReserved, requestToBuy } from '../../src/features/orders/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

// Step before an order exists: choose collection or delivery and send the request.
// Nothing is charged here. ZedMarket does not take or hold payment.
export default function Checkout() {
  const { listingId } = useLocalSearchParams<{ listingId: string }>();
  const router = useRouter();

  const [listing, setListing] = useState<ListingDetail | null>(null);
  const [reserved, setReserved] = useState(false);
  const [fulfilment, setFulfilment] = useState<Fulfilment>('collection');
  const [address, setAddress] = useState('');
  const [note, setNote] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!listingId) return;
    (async () => {
      try {
        const [detail, isReserved] = await Promise.all([fetchListing(listingId, true), isListingReserved(listingId)]);
        setListing(detail);
        setReserved(isReserved);
      } catch (e) {
        setError(friendlyError(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [listingId]);

  async function submit() {
    if (!listing) return;
    const problem = validateCheckout({ fulfilment, address, note });
    if (problem) {
      setError(problem);
      return;
    }
    setBusy(true);
    setError('');
    try {
      const order = await requestToBuy(listing.id, { fulfilment, address, note });
      router.replace(`/order/${order.id}`);
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator color={colors.primary} />
      </View>
    );
  }
  if (!listing) {
    return (
      <View style={styles.center}>
        <Notice tone="error">{error || 'This listing is not available.'}</Notice>
      </View>
    );
  }

  const unavailable = listing.status !== 'active' || reserved;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      <View style={styles.card}>
        <Text style={styles.title}>{listing.title}</Text>
        <Text style={styles.meta}>Sold by {listing.sellerName}</Text>
        <Text style={styles.price}>{formatKwacha(listing.price)}</Text>
      </View>

      {reserved ? <Notice tone="warning">This item is reserved for another buyer right now. Try again later.</Notice> : null}

      <SectionTitle>How do you want to get it?</SectionTitle>
      <View style={styles.row}>
        <Chip label="Collection" selected={fulfilment === 'collection'} onPress={() => setFulfilment('collection')} />
        <Chip label="Delivery" selected={fulfilment === 'delivery'} onPress={() => setFulfilment('delivery')} />
      </View>

      {fulfilment === 'delivery' ? (
        <>
          <Field
            label="Delivery address or landmark"
            value={address}
            onChangeText={setAddress}
            placeholder="For example: near the blue gate, Kabulonga"
            multiline
            maxLength={300}
          />
          <Notice>The seller tells you the delivery fee when they confirm. You can cancel before the item is handed over.</Notice>
        </>
      ) : (
        <Notice>You and the seller agree where and when to meet. Message them from the listing or the order.</Notice>
      )}

      <Field label="Note for the seller (optional)" value={note} onChangeText={setNote} multiline maxLength={300} />

      <View style={styles.card}>
        <Text style={styles.line}>Item {formatKwacha(listing.price)}</Text>
        <Text style={styles.line}>{fulfilment === 'delivery' ? 'Delivery fee: set by the seller' : 'No delivery fee'}</Text>
      </View>

      <Notice>
        Nothing is charged here. You pay the seller directly. ZedMarket does not take or hold your money, so only pay when you
        are happy with the item.
      </Notice>

      {error ? <Notice tone="error">{error}</Notice> : null}
      <Button title="Send request to the seller" onPress={submit} loading={busy} disabled={unavailable} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  title: { fontSize: 18, fontWeight: '700', color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
  price: { fontSize: 22, fontWeight: '700', color: colors.text },
  line: { fontSize: 15, color: colors.text },
  row: { flexDirection: 'row', gap: spacing.sm },
});
