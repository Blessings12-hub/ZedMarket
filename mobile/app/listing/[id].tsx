import { useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Alert, Dimensions, Image, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Notice, SectionTitle, VerifiedBadge } from '../../src/components/ui';
import { startConversation } from '../../src/features/chat/api';
import { fetchListing, fetchSellerStats, isFavourite, setFavourite, setListingStatus } from '../../src/features/listings/api';
import type { ListingDetail, SellerStats } from '../../src/features/listings/types';
import { requestToBuy } from '../../src/features/orders/api';
import { conditionLabel } from '../../src/domain/listing';
import { formatKwacha } from '../../src/domain/money';
import { friendlyError } from '../../src/lib/errors';
import { listingImageUrl } from '../../src/lib/supabase';
import { colors, radius, spacing } from '../../src/theme';

const PHOTO_WIDTH = Dimensions.get('window').width;

export default function ListingScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const { userId } = useAuth();

  const [listing, setListing] = useState<ListingDetail | null>(null);
  const [stats, setStats] = useState<SellerStats | null>(null);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const detail = await fetchListing(id);
      setListing(detail);
      const [sellerStats, fav] = await Promise.all([fetchSellerStats(detail.sellerId), isFavourite(id)]);
      setStats(sellerStats);
      setSaved(fav);
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  if (error) {
    return (
      <View style={styles.center}>
        <Notice tone="error">{error}</Notice>
      </View>
    );
  }
  if (!listing) {
    return (
      <View style={styles.center}>
        <ActivityIndicator color={colors.primary} />
      </View>
    );
  }

  const isOwner = listing.sellerId === userId;
  const available = listing.status === 'active';

  async function toggleSaved() {
    const next = !saved;
    setSaved(next);
    try {
      await setFavourite(listing!.id, next);
    } catch (e) {
      setSaved(!next);
      setError(friendlyError(e));
    }
  }

  async function messageSeller() {
    setBusy(true);
    try {
      const conversationId = await startConversation(listing!.id);
      router.push(`/chat/${conversationId}`);
    } catch (e) {
      Alert.alert('Could not start the chat', friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  function askToBuy() {
    Alert.alert(
      'Request to buy',
      `Send ${listing!.sellerName} a request to buy this for ${formatKwacha(listing!.price)}? You arrange collection and payment with the seller. Nothing is charged here.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Send request',
          onPress: async () => {
            setBusy(true);
            try {
              await requestToBuy(listing!.id);
              router.push('/orders');
            } catch (e) {
              Alert.alert('Could not send the request', friendlyError(e));
            } finally {
              setBusy(false);
            }
          },
        },
      ],
    );
  }

  async function changeStatus(status: 'active' | 'sold' | 'unavailable') {
    setBusy(true);
    try {
      await setListingStatus(listing!.id, status);
      await load();
    } catch (e) {
      Alert.alert('Could not update the listing', friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={{ paddingBottom: spacing.xl }}>
      {listing.imagePaths.length > 0 ? (
        <ScrollView horizontal pagingEnabled showsHorizontalScrollIndicator={false}>
          {listing.imagePaths.map((path) => (
            <Image key={path} source={{ uri: listingImageUrl(path) }} style={styles.photo} resizeMode="cover" />
          ))}
        </ScrollView>
      ) : (
        <View style={[styles.photo, { backgroundColor: colors.primarySoft }]} />
      )}

      <View style={styles.body}>
        {!available ? (
          <Notice tone="warning">
            {listing.status === 'sold' ? 'This item has been sold.' : 'This item is not available right now.'}
          </Notice>
        ) : null}

        <Text style={styles.price}>{formatKwacha(listing.price)}</Text>
        <Text style={styles.title}>{listing.title}</Text>
        <Text style={styles.meta}>
          {conditionLabel(listing.condition)} · {listing.categoryName} · {listing.area}, Lusaka
        </Text>
        <Text style={styles.meta}>Posted {new Date(listing.postedAt).toLocaleDateString('en-ZM', { day: 'numeric', month: 'short', year: 'numeric' })}</Text>

        {listing.description ? <Text style={styles.description}>{listing.description}</Text> : null}

        {listing.warrantyInfo || listing.returnPolicy ? (
          <View style={styles.card}>
            {listing.warrantyInfo ? (
              <>
                <SectionTitle>Warranty</SectionTitle>
                <Text style={styles.cardText}>{listing.warrantyInfo}</Text>
              </>
            ) : null}
            {listing.returnPolicy ? (
              <>
                <SectionTitle>Returns</SectionTitle>
                <Text style={styles.cardText}>{listing.returnPolicy}</Text>
              </>
            ) : null}
          </View>
        ) : null}

        <View style={styles.card}>
          <SectionTitle>Seller</SectionTitle>
          <Text style={styles.sellerName}>{listing.sellerName}</Text>
          <VerifiedBadge level={listing.sellerLevel} />
          <Button title="See reviews" variant="secondary" onPress={() => router.push(`/seller/${listing.sellerId}`)} />
          <Text style={styles.meta}>
            {stats && stats.reviewCount > 0
              ? `${stats.averageRating.toFixed(1)} out of 5 from ${stats.reviewCount} review${stats.reviewCount === 1 ? '' : 's'}`
              : 'No reviews yet'}
            {stats && stats.completedOrders > 0 ? ` · ${stats.completedOrders} completed order${stats.completedOrders === 1 ? '' : 's'}` : ''}
          </Text>
        </View>

        <Notice>
          Look at the item before you pay, and meet in a public place. Keep your messages in ZedMarket so there is a record if something goes wrong.
        </Notice>

        {isOwner ? (
          <View style={{ gap: spacing.sm }}>
            {listing.status === 'active' ? (
              <>
                <Button title="Mark as sold" onPress={() => changeStatus('sold')} loading={busy} />
                <Button title="Pause this listing" variant="secondary" onPress={() => changeStatus('unavailable')} disabled={busy} />
              </>
            ) : listing.status === 'unavailable' ? (
              <Button title="Make available again" onPress={() => changeStatus('active')} loading={busy} />
            ) : null}
          </View>
        ) : (
          <View style={{ gap: spacing.sm }}>
            <Button title="Request to buy" onPress={askToBuy} disabled={!available || busy} />
            <Button title="Message seller" variant="secondary" onPress={messageSeller} disabled={!available || busy} />
            <Button title={saved ? 'Remove from saved' : 'Save for later'} variant="secondary" onPress={toggleSaved} />
            <Button
              title="Report this listing"
              variant="danger"
              onPress={() => router.push({ pathname: '/report', params: { targetType: 'listing', targetId: listing.id } })}
            />
          </View>
        )}
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl, backgroundColor: colors.background },
  photo: { width: PHOTO_WIDTH, height: PHOTO_WIDTH * 0.75 },
  body: { padding: spacing.lg, gap: spacing.md },
  price: { fontSize: 28, fontWeight: '800', color: colors.text },
  title: { fontSize: 20, fontWeight: '600', color: colors.text },
  meta: { fontSize: 14, color: colors.muted },
  description: { fontSize: 16, lineHeight: 24, color: colors.text },
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.lg,
    gap: spacing.xs,
  },
  cardText: { fontSize: 15, lineHeight: 22, color: colors.text, marginBottom: spacing.sm },
  sellerName: { fontSize: 17, fontWeight: '600', color: colors.text },
});
