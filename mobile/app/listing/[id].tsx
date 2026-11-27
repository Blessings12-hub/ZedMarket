import { useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Dimensions, ScrollView, Share, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { ListingRail } from '../../src/components/ListingRail';
import { RetryImage } from '../../src/components/RetryImage';
import { Button, Notice, SectionTitle, VerifiedBadge } from '../../src/components/ui';
import { deliverySummary } from '../../src/domain/locations';
import { fetchListingDeliveryInfo } from '../../src/features/locations/api';
import { toggle as toggleCompare, useCompare } from '../../src/features/comparison/store';
import { addItem, useCart } from '../../src/features/cart/store';
import { inCart } from '../../src/domain/cart';
import { startConversation } from '../../src/features/chat/api';
import { fetchMyRoles } from '../../src/features/admin/api';
import {
  featureListing,
  fetchListing,
  fetchSellerStats,
  fetchSimilar,
  isFavourite,
  recordView,
  setFavourite,
  setListingStatus,
  unfeatureListing,
} from '../../src/features/listings/api';
import type { ListingDetail, ListingSummary, SellerStats } from '../../src/features/listings/types';
import { isListingReserved } from '../../src/features/orders/api';
import { conditionLabel } from '../../src/domain/listing';
import { formatKwacha } from '../../src/domain/money';
import { listingLink, listingShareMessage, webBase } from '../../src/domain/share';
import { friendlyError } from '../../src/lib/errors';
import { listingImageUrl } from '../../src/lib/supabase';
import { colors, radius, spacing } from '../../src/theme';
import { showAlert } from '../../src/lib/dialog';

const PHOTO_WIDTH = Dimensions.get('window').width;

export default function ListingScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const compareIds = useCompare();
  const cartItems = useCart();
  const { userId, session } = useAuth();
  const signedIn = !!session;

  const [listing, setListing] = useState<ListingDetail | null>(null);
  const [deliversTo, setDeliversTo] = useState<string | null>(null);
  const [stats, setStats] = useState<SellerStats | null>(null);
  const [saved, setSaved] = useState(false);
  const [similar, setSimilar] = useState<ListingSummary[]>([]);
  const [isModerator, setIsModerator] = useState(false);
  const [reserved, setReserved] = useState(false);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const detail = await fetchListing(id, signedIn);
      setListing(detail);
      fetchListingDeliveryInfo(id).then((i) => setDeliversTo(deliverySummary(i))).catch(() => setDeliversTo(null));
      const [sellerStats, fav, more, roles, isReserved] = await Promise.all([
        fetchSellerStats(detail.sellerId).catch(() => null),
        signedIn ? isFavourite(id).catch(() => false) : Promise.resolve(false),
        fetchSimilar(id).catch(() => [] as ListingSummary[]),
        userId ? fetchMyRoles(userId).catch(() => []) : Promise.resolve([]),
        isListingReserved(id).catch(() => false),
      ]);
      setReserved(isReserved);
      setStats(sellerStats);
      setSaved(fav);
      setSimilar(more);
      setIsModerator(roles.some((r) => r === 'moderator'));
      if (detail.status === 'active') recordView(id);
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [id, signedIn, userId]);

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

  // Guests can look at everything; actions that need an account send them to sign in.
  function needAccount(): boolean {
    if (signedIn) return false;
    showAlert('Sign in to continue', 'Create a free account or sign in to do that.', [
      { text: 'Not now', style: 'cancel' },
      { text: 'Sign in', onPress: () => router.push('/sign-in') },
    ]);
    return true;
  }

  async function shareListing() {
    const link = listingLink(webBase(process.env.EXPO_PUBLIC_WEB_URL), listing!.id);
    try {
      await Share.share({ message: listingShareMessage({ title: listing!.title, price: listing!.price, link }) });
    } catch {
      // Closing the share sheet is not an error.
    }
  }

  async function toggleFeatured(on: boolean) {
    setBusy(true);
    try {
      if (on) await featureListing(listing!.id, 7);
      else await unfeatureListing(listing!.id);
      showAlert(on ? 'Featured for 7 days' : 'Removed from featured');
    } catch (e) {
      showAlert('Could not change featured status', friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  async function toggleSaved() {
    if (needAccount()) return;
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
    if (needAccount()) return;
    setBusy(true);
    try {
      const conversationId = await startConversation(listing!.id);
      router.push(`/chat/${conversationId}`);
    } catch (e) {
      showAlert('Could not start the chat', friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  function addToCartPressed() {
    if (!listing) return;
    void addItem({ listingId: listing.id, title: listing.title, price: listing.price, sellerName: listing.sellerName, imagePath: listing.imagePaths[0] ?? listing.imagePath, addedAt: new Date().toISOString() });
  }

  function askToBuy() {
    if (needAccount()) return;
    router.push(`/checkout/${listing!.id}`);
  }

  async function changeStatus(status: 'active' | 'sold' | 'unavailable') {
    setBusy(true);
    try {
      await setListingStatus(listing!.id, status);
      await load();
    } catch (e) {
      showAlert('Could not update the listing', friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={{ paddingBottom: spacing.xl }}>
      {listing.imagePaths.length > 0 ? (
        <ScrollView horizontal pagingEnabled showsHorizontalScrollIndicator={false}>
          {listing.imagePaths.map((path) => (
            <RetryImage key={path} source={{ uri: listingImageUrl(path) }} style={styles.photo} resizeMode="cover" />
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
          {conditionLabel(listing.condition)} · {listing.categoryName} · {listing.area}
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
          {deliversTo ? <Text style={styles.meta}>{deliversTo}</Text> : null}
          <Button title="View seller page" variant="secondary" onPress={() => router.push(`/seller/${listing.sellerId}`)} />
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
                <Button title="Share" variant="secondary" onPress={shareListing} />
                <Button title="Pause this listing" variant="secondary" onPress={() => changeStatus('unavailable')} disabled={busy} />
              </>
            ) : listing.status === 'unavailable' ? (
              <Button title="Make available again" onPress={() => changeStatus('active')} loading={busy} />
            ) : null}
          </View>
        ) : (
          <View style={{ gap: spacing.sm }}>
            {reserved ? <Notice tone="warning">Reserved for another buyer right now. It may come back if that order falls through.</Notice> : null}
            <Button title="Request to buy" onPress={askToBuy} disabled={!available || reserved || busy} />
            {inCart(cartItems, listing.id) ? (
              <Button title="In your cart - view cart" variant="secondary" onPress={() => router.push('/(tabs)/cart')} />
            ) : (
              <Button title="Add to cart" variant="secondary" onPress={addToCartPressed} disabled={!available || reserved || busy} />
            )}
            <Button title={compareIds.includes(listing.id) ? 'Remove from compare' : 'Compare with other items'} variant="secondary" onPress={() => { if (toggleCompare(listing.id)) showAlert('Compare list is full', 'You can compare up to 4 items. Remove one first.'); }} />
            {compareIds.length >= 2 ? <Button title={`Compare ${compareIds.length} items`} onPress={() => router.push('/compare')} /> : null}
            <Button title="Message seller" variant="secondary" onPress={messageSeller} disabled={!available || busy} />
            <Button title={saved ? 'Remove from saved' : 'Save for later'} variant="secondary" onPress={toggleSaved} />
            <Button title="Share" variant="secondary" onPress={shareListing} />
            <Button
              title="Report this listing"
              variant="danger"
              onPress={() => {
                if (needAccount()) return;
                router.push({ pathname: '/report', params: { targetType: 'listing', targetId: listing.id } });
              }}
            />
            {isModerator && available ? (
              <>
                <Button title="Feature for 7 days (staff)" variant="secondary" onPress={() => toggleFeatured(true)} disabled={busy} />
                <Button title="Remove from featured (staff)" variant="secondary" onPress={() => toggleFeatured(false)} disabled={busy} />
              </>
            ) : null}
          </View>
        )}
      </View>

      <ListingRail title="More like this" items={similar} />
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
