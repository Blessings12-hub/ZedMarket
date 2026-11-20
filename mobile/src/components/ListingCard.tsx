import { useRouter } from 'expo-router';
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';

import { conditionLabel } from '../domain/listing';
import { formatKwacha } from '../domain/money';
import type { ListingSummary } from '../features/listings/types';
import { listingImageUrl } from '../lib/supabase';
import { colors, radius, spacing } from '../theme';
import { VerifiedBadge } from './ui';

export function ListingCard({ listing }: { listing: ListingSummary }) {
  const router = useRouter();

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`${listing.title}, ${formatKwacha(listing.price)}`}
      style={styles.card}
      onPress={() => router.push(`/listing/${listing.id}`)}
    >
      {listing.imagePath ? (
        <Image source={{ uri: listingImageUrl(listing.imagePath) }} style={styles.image} resizeMode="cover" />
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
  body: { padding: spacing.md, gap: spacing.xs },
  price: { fontSize: 17, fontWeight: '700', color: colors.text },
  title: { fontSize: 14, color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
});
