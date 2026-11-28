import { useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, FlatList, Linking, Pressable, Share, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { ListingCard } from '../../src/components/ListingCard';
import { Button, Notice, SectionTitle, VerifiedBadge } from '../../src/components/ui';
import { replySpeedLabel, type ReplySpeed } from '../../src/domain/replySpeed';
import { sellerLink, sellerShareMessage, webBase, whatsappShareUrl } from '../../src/domain/share';
import { fetchReplySpeed } from '../../src/features/launch/api';
import { fetchListings, fetchSellerPage, PAGE_SIZE } from '../../src/features/listings/api';
import { defaultFilters, type ListingSummary, type SellerPage } from '../../src/features/listings/types';
import { fetchReviewsAbout, type ReviewItem } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

// A seller's public page: who they are, what they are selling and what buyers said.
// Anyone can open it, including guests, so it also works as the link a seller shares.
export default function SellerStorefront() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const { session } = useAuth();

  const [seller, setSeller] = useState<SellerPage | null>(null);
  const [items, setItems] = useState<ListingSummary[]>([]);
  const [page, setPage] = useState(0);
  const [finished, setFinished] = useState(false);
  const [reviews, setReviews] = useState<ReviewItem[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [missing, setMissing] = useState(false);
  const [speed, setSpeed] = useState<ReplySpeed | null>(null);

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    (async () => {
      try {
        const profile = await fetchSellerPage(id);
        if (cancelled) return;
        if (!profile) {
          setMissing(true);
          return;
        }
        setSeller(profile);
        fetchReplySpeed(id).then((s) => { if (!cancelled) setSpeed(s); });
        const first = await fetchListings('', defaultFilters, 0, id);
        if (cancelled) return;
        setItems(first);
        setFinished(first.length < PAGE_SIZE);
        // Reviews are for signed-in people; guests see the rating summary only.
        if (session) setReviews(await fetchReviewsAbout(id).catch(() => []));
      } catch (e) {
        if (!cancelled) setError(friendlyError(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [id, session]);

  async function shareWhatsApp() {
    if (!seller) return;
    const link = sellerLink(webBase(process.env.EXPO_PUBLIC_WEB_URL), seller.sellerId);
    try {
      await Linking.openURL(whatsappShareUrl(sellerShareMessage({ name: seller.displayName, link })));
    } catch {
      setError('WhatsApp could not be opened. Use Share instead.');
    }
  }

  const loadMore = useCallback(async () => {
    if (!id || finished || loading) return;
    try {
      const next = await fetchListings('', defaultFilters, page + 1, id);
      setItems((prev) => [...prev, ...next]);
      setPage(page + 1);
      setFinished(next.length < PAGE_SIZE);
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [id, finished, loading, page]);

  async function shareStorefront() {
    if (!seller) return;
    const link = sellerLink(webBase(process.env.EXPO_PUBLIC_WEB_URL), seller.sellerId);
    try {
      await Share.share({ message: sellerShareMessage({ name: seller.displayName, link }) });
    } catch {
      // Closing the share sheet is not an error.
    }
  }

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator color={colors.primary} />
      </View>
    );
  }
  if (missing || !seller) {
    return (
      <View style={styles.center}>
        <Notice tone={error ? 'error' : 'info'}>{error || 'This seller page is not available.'}</Notice>
      </View>
    );
  }

  const since = new Date(seller.memberSince).toLocaleDateString('en-ZM', { month: 'long', year: 'numeric' });

  const header = (
    <View style={styles.head}>
      <View style={styles.card}>
        <Text style={styles.name}>{seller.displayName}</Text>
        <VerifiedBadge level={seller.level} />
        {replySpeedLabel(speed) ? <Text style={styles.reply}>{replySpeedLabel(speed)}</Text> : null}
        {seller.bio ? <Text style={styles.bio}>{seller.bio}</Text> : null}
        <Text style={styles.meta}>Member since {since}</Text>
        <Text style={styles.meta}>
          {seller.reviewCount > 0
            ? `${seller.averageRating.toFixed(1)} out of 5 from ${seller.reviewCount} review${seller.reviewCount === 1 ? '' : 's'}`
            : 'No reviews yet'}
          {seller.completedOrders > 0 ? ` · ${seller.completedOrders} completed order${seller.completedOrders === 1 ? '' : 's'}` : ''}
        </Text>
        <Button title="Share this seller" variant="secondary" onPress={shareStorefront} />
        <Button title="Share on WhatsApp" variant="secondary" onPress={shareWhatsApp} />
      </View>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <SectionTitle>{`For sale (${seller.activeListings})`}</SectionTitle>
      {items.length === 0 ? <Text style={styles.empty}>Nothing for sale right now.</Text> : null}
    </View>
  );

  const footer = (
    <View style={styles.head}>
      <SectionTitle>Reviews</SectionTitle>
      {!session ? (
        <Pressable accessibilityRole="button" onPress={() => router.push('/sign-in')}>
          <Text style={styles.link}>Sign in to read what buyers wrote</Text>
        </Pressable>
      ) : reviews.length === 0 ? (
        <Text style={styles.empty}>No reviews yet.</Text>
      ) : (
        reviews.map((r) => (
          <View key={r.id} style={styles.card}>
            <Text style={styles.rating}>{r.rating} out of 5</Text>
            {r.comment ? <Text style={styles.comment}>{r.comment}</Text> : null}
            <Text style={styles.meta}>
              {r.reviewerName} · {new Date(r.createdAt).toLocaleDateString()}
            </Text>
            <Pressable
              accessibilityRole="button"
              onPress={() => router.push({ pathname: '/report', params: { targetType: 'review', targetId: r.id } })}
            >
              <Text style={styles.report}>Report this review</Text>
            </Pressable>
          </View>
        ))
      )}
    </View>
  );

  return (
    <FlatList
      style={styles.screen}
      data={items}
      keyExtractor={(i) => i.id}
      numColumns={2}
      columnWrapperStyle={{ gap: spacing.md, paddingHorizontal: spacing.lg }}
      contentContainerStyle={{ gap: spacing.md, paddingBottom: spacing.xl }}
      ListHeaderComponent={header}
      ListFooterComponent={footer}
      renderItem={({ item }) => <ListingCard listing={item} />}
      onEndReached={loadMore}
      onEndReachedThreshold={0.4}
    />
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl, backgroundColor: colors.background },
  head: { padding: spacing.lg, gap: spacing.md },
  reply: { fontSize: 13, color: colors.muted },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  name: { fontSize: 22, fontWeight: '700', color: colors.text },
  bio: { fontSize: 15, lineHeight: 22, color: colors.text },
  rating: { fontSize: 16, fontWeight: '700', color: colors.text },
  comment: { fontSize: 15, lineHeight: 22, color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
  link: { color: colors.primary, fontWeight: '600', textDecorationLine: 'underline' },
  report: { fontSize: 13, color: colors.muted, textDecorationLine: 'underline', marginTop: spacing.xs },
  empty: { color: colors.muted },
});
