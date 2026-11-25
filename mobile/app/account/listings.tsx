import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Notice } from '../../src/components/ui';
import { formatKwacha } from '../../src/domain/money';
import { fetchMyListings } from '../../src/features/listings/api';
import type { MyListing } from '../../src/features/listings/types';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

function listingState(l: MyListing): string {
  if (l.status === 'draft') return 'Draft';
  if (l.status === 'sold') return 'Sold';
  if (l.status === 'unavailable') return 'Paused';
  if (l.moderationStatus === 'pending') return 'Waiting for review';
  if (l.moderationStatus === 'rejected') return 'Not approved';
  return 'Live';
}

// The "My listings" list that used to sit on the Profile tab, unchanged: same states, same appeal link.
export default function MyListings() {
  const router = useRouter();
  const { userId } = useAuth();
  const [listings, setListings] = useState<MyListing[] | null>(null);
  const [error, setError] = useState('');

  useFocusEffect(
    useCallback(() => {
      if (!userId) return;
      fetchMyListings(userId).then((r) => { setListings(r); setError(''); }).catch((e) => { setListings([]); setError(friendlyError(e)); });
    }, [userId]),
  );

  if (!listings) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {listings.length === 0 ? <Text style={styles.hint}>You have not posted anything yet.</Text> : null}
      {listings.map((l) => (
        <Pressable key={l.id} accessibilityRole="button" style={styles.listing} onPress={() => router.push(`/listing/${l.id}`)}>
          <View style={{ flex: 1 }}>
            <Text style={styles.listingTitle} numberOfLines={1}>{l.title}</Text>
            <Text style={styles.hint}>{formatKwacha(l.price)}</Text>
            {l.moderationStatus === 'rejected' && l.moderationNote ? <Text style={styles.reason}>{l.moderationNote}</Text> : null}
            {l.moderationStatus === 'rejected' ? (
              <Pressable accessibilityRole="button" onPress={() => router.push({ pathname: '/appeal', params: { targetType: 'listing', targetId: l.id } })}>
                <Text style={styles.appeal}>Appeal this decision</Text>
              </Pressable>
            ) : null}
          </View>
          <Text style={styles.state}>{listingState(l)}</Text>
        </Pressable>
      ))}
      <Button title="Post a listing" onPress={() => router.push('/(tabs)/sell')} />
      <Button title="Prices, copies and status history" variant="secondary" onPress={() => router.push('/seller/listings')} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, justifyContent: 'center', backgroundColor: colors.background },
  hint: { fontSize: 14, color: colors.muted, lineHeight: 20 },
  listing: { flexDirection: 'row', alignItems: 'center', gap: spacing.md, backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md },
  listingTitle: { fontSize: 16, fontWeight: '600', color: colors.text },
  state: { fontSize: 13, fontWeight: '600', color: colors.primary },
  reason: { fontSize: 13, color: colors.danger, marginTop: 2 },
  appeal: { fontSize: 13, color: colors.primary, textDecorationLine: 'underline', marginTop: 4 },
});
