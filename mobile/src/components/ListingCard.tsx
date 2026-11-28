import { useRouter } from 'expo-router';
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { conditionLabel } from '../domain/listing';
import { formatKwacha } from '../domain/money';
import type { ListingSummary } from '../features/listings/types';
import { useDataSaver } from '../lib/dataSaver';
import { listingImageUrl } from '../lib/supabase';
import { colors, radius, spacing } from '../theme';
import { RetryImage } from './RetryImage';
import { VerifiedBadge } from './ui';

export function ListingCard({ listing, width }: { listing: ListingSummary; width?: number }) {
  const router = useRouter();
  const saver = useDataSaver();
  const [shown, setShown] = useState(false);
  const hidePhoto = saver && !shown && !!listing.imagePath;

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`${listing.title}, ${formatKwacha(listing.price)}`}
      style={[styles.card, width ? { flex: 0, width } : null]}
      onPress={() => router.push(`/listing/${listing.id}`)}
    >
      {hidePhoto ? (
        <Pressable accessibilityRole="button" accessibilityLabel="Show photo" onPress={() => setShown(true)} style={[styles.image, styles.noImage, styles.showPhoto]}>
          <Text style={styles.showText}>Show photo</Text>
        </Pressable>
      ) : listing.imagePath ? (
        <RetryImage source={{ uri: listingImageUrl(listing.imagePath) }} style={styles.image} resizeMode="cover" />
      ) : (
        <View style={[styles.image, styles.noImage]} />
      )}
      <View style={styles.body}>
        <Text style={styles.price}>{formatKwacha(listing.price)}</Text>
        <Text style={styles.title} numberOfLines={2}>
          {listing.title}
        </Text>
        <Text style={styles.meta} numberOfLines={1}>
          {listing.area} · {conditionLabel(listing.condition)}
        </Text>
        <VerifiedBadge level={listing.sellerLevel} />
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  card: {
    flex: 1,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    overflow: 'hidden',
  },
  image: { width: '100%', aspectRatio: 4 / 3, backgroundColor: colors.primarySoft },
  noImage: { backgroundColor: colors.primarySoft },
  showPhoto: { alignItems: 'center', justifyContent: 'center' },
  showText: { fontSize: 13, fontWeight: '600', color: colors.primary },
  body: { padding: spacing.md, gap: spacing.xs },
  price: { fontSize: 17, fontWeight: '700', color: colors.text },
  title: { fontSize: 14, color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
});
