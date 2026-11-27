import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Notice } from '../../src/components/ui';
import { cartTotal, effectiveQuantity } from '../../src/domain/cart';
import { formatKwacha } from '../../src/domain/money';
import { removeItem, setQuantity, useCart } from '../../src/features/cart/store';
import { fetchStockInfo } from '../../src/features/orders/api';
import { listingImageUrl } from '../../src/lib/supabase';
import { colors, radius, spacing } from '../../src/theme';

// Items the buyer plans to request. Nothing is charged or reserved here: each item is requested from its seller
// at checkout, and every seller confirms their own request.
export default function CartScreen() {
  const router = useRouter();
  const { session } = useAuth();
  const items = useCart();
  // How many of each item can be ordered right now. Missing or null means a one-off item (or the count could not be read):
  // then only 1 is shown and asked for, so the cart never promises more than checkout will ask the database for.
  const [stock, setStock] = useState<Record<string, number | null>>({});
  const ids = items.map((i) => i.listingId).join(',');
  useFocusEffect(
    useCallback(() => {
      let live = true;
      (async () => {
        const entries = await Promise.all(
          ids.split(',').filter(Boolean).map(async (id) => {
            try {
              return [id, await fetchStockInfo(id)] as const;
            } catch (e) {
              console.error('[cart] stock count failed', id, e);
              return [id, null] as const;
            }
          }),
        );
        if (live) setStock(Object.fromEntries(entries));
      })();
      return () => { live = false; };
    }, [ids]),
  );

  const qtyFor = (listingId: string) => {
    const item = items.find((x) => x.listingId === listingId);
    return item ? effectiveQuantity(item, stock[listingId]) : 1;
  };

  function checkout(listingId: string) {
    if (!session) {
      router.push('/sign-in');
      return;
    }
    router.push({ pathname: '/checkout/[listingId]', params: { listingId, quantity: String(qtyFor(listingId)) } });
  }

  if (items.length === 0) {
    return (
      <View style={styles.empty}>
        <Text style={styles.emptyTitle}>Your cart is empty</Text>
        <Text style={styles.emptyText}>Add items from a listing and they wait here until you are ready to ask the seller.</Text>
        <Button title="Browse items" onPress={() => router.push('/')} />
      </View>
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Notice>Each seller confirms their own request, so you request items one at a time. ZedMarket does not take payment here.</Notice>
      {items.map((i) => (
        <View key={i.listingId} style={styles.card}>
          <View style={styles.row}>
            {i.imagePath ? <Image source={{ uri: listingImageUrl(i.imagePath) }} style={styles.thumb} /> : <View style={[styles.thumb, styles.noImage]} />}
            <View style={{ flex: 1, gap: 2 }}>
              <Text style={styles.title} numberOfLines={2}>{i.title}</Text>
              {i.sellerName ? <Text style={styles.meta}>Sold by {i.sellerName}</Text> : null}
              <Text style={styles.price}>{formatKwacha(i.price)}{effectiveQuantity(i, stock[i.listingId]) > 1 ? ` each · ${formatKwacha(i.price * effectiveQuantity(i, stock[i.listingId]))}` : ''}</Text>
            </View>
          </View>
          {(stock[i.listingId] ?? 0) > 1 ? (
            <View style={styles.actions}>
              <View style={{ flex: 1 }}><Button title="−" variant="secondary" disabled={effectiveQuantity(i, stock[i.listingId]) <= 1} onPress={() => void setQuantity(i.listingId, effectiveQuantity(i, stock[i.listingId]) - 1)} /></View>
              <Text style={styles.price}>Quantity {effectiveQuantity(i, stock[i.listingId])}</Text>
              <View style={{ flex: 1 }}><Button title="+" variant="secondary" disabled={effectiveQuantity(i, stock[i.listingId]) >= (stock[i.listingId] ?? 1)} onPress={() => void setQuantity(i.listingId, effectiveQuantity(i, stock[i.listingId]) + 1)} /></View>
            </View>
          ) : null}
          <View style={styles.actions}>
            <View style={{ flex: 1 }}><Button title="Request to buy" onPress={() => checkout(i.listingId)} /></View>
            <View style={{ flex: 1 }}><Button title="View" variant="secondary" onPress={() => router.push(`/listing/${i.listingId}`)} /></View>
            <View style={{ flex: 1 }}><Button title="Remove" variant="secondary" onPress={() => void removeItem(i.listingId)} /></View>
          </View>
        </View>
      ))}
      <View style={styles.total}>
        <Text style={styles.meta}>{items.length} {items.length === 1 ? 'item' : 'items'} · total of listed prices</Text>
        <Text style={styles.price}>{formatKwacha(cartTotal(items, stock))}</Text>
        <Text style={styles.meta}>Delivery fees are set by each seller when they confirm.</Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl * 2 },
  empty: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: spacing.md, padding: spacing.xl, backgroundColor: colors.background },
  emptyTitle: { fontSize: 18, fontWeight: '600', color: colors.text },
  emptyText: { color: colors.muted, textAlign: 'center' },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.md },
  row: { flexDirection: 'row', gap: spacing.md },
  thumb: { width: 72, height: 72, borderRadius: radius.sm },
  noImage: { backgroundColor: colors.primarySoft },
  actions: { flexDirection: 'row', gap: spacing.sm },
  title: { fontSize: 16, fontWeight: '600', color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
  price: { fontSize: 18, fontWeight: '700', color: colors.text },
  total: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
});
