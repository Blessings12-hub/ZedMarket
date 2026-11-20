import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Notice, SectionTitle, VerifiedBadge } from '../../src/components/ui';
import { formatKwacha } from '../../src/domain/money';
import { fetchMyRoles } from '../../src/features/admin/api';
import { fetchMyListings } from '../../src/features/listings/api';
import type { MyListing, VerificationLevel } from '../../src/features/listings/types';
import { friendlyError } from '../../src/lib/errors';
import { supabase } from '../../src/lib/supabase';
import { colors, radius, spacing } from '../../src/theme';

type Profile = { display_name: string; verification_level: VerificationLevel; account_state: 'active' | 'restricted' | 'suspended' };

function listingState(l: MyListing): string {
  if (l.status === 'draft') return 'Draft';
  if (l.status === 'sold') return 'Sold';
  if (l.status === 'unavailable') return 'Paused';
  if (l.moderationStatus === 'pending') return 'Waiting for review';
  if (l.moderationStatus === 'rejected') return 'Not approved';
  return 'Live';
}

export default function AccountScreen() {
  const router = useRouter();
  const { userId, session } = useAuth();
  const [profile, setProfile] = useState<Profile | null>(null);
  const [listings, setListings] = useState<MyListing[]>([]);
  const [isStaff, setIsStaff] = useState(false);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      const [p, mine, roles] = await Promise.all([
        supabase.from('profiles').select('display_name, verification_level, account_state').eq('id', userId).single(),
        fetchMyListings(userId),
        fetchMyRoles(userId).catch(() => []),
      ]);
      if (p.error) throw p.error;
      setProfile(p.data as Profile);
      setListings(mine);
      setIsStaff(roles.length > 0);
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [userId]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}

      <View style={styles.card}>
        <Text style={styles.name}>{profile?.display_name ?? ''}</Text>
        <Text style={styles.email}>{session?.user.email}</Text>
        {profile ? <VerifiedBadge level={profile.verification_level} /> : null}
        {profile?.verification_level === 'unverified' ? (
          <Text style={styles.hint}>Verified sellers get a badge buyers can see.</Text>
        ) : null}
        {profile && profile.account_state !== 'active' ? (
          <>
            <Notice tone="warning">
              {profile.account_state === 'suspended' ? 'Your account is suspended.' : 'Your account is restricted, so you cannot post new listings.'}
            </Notice>
            <Button title="Appeal this decision" variant="secondary" onPress={() => router.push({ pathname: '/appeal', params: { targetType: 'user', targetId: userId } })} />
          </>
        ) : null}
      </View>

      <Button title="Your orders" variant="secondary" onPress={() => router.push('/orders')} />
      <Button title="Get verified" variant="secondary" onPress={() => router.push('/verify')} />
      <Button title="Saved items" variant="secondary" onPress={() => router.push('/saved')} />
      {isStaff ? <Button title="Staff tools" variant="secondary" onPress={() => router.push('/admin')} /> : null}

      <SectionTitle>My listings</SectionTitle>
      {listings.length === 0 ? (
        <Text style={styles.hint}>You have not posted anything yet.</Text>
      ) : (
        listings.map((l) => (
          <Pressable key={l.id} accessibilityRole="button" style={styles.listing} onPress={() => router.push(`/listing/${l.id}`)}>
            <View style={{ flex: 1 }}>
              <Text style={styles.listingTitle} numberOfLines={1}>
                {l.title}
              </Text>
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
        ))
      )}

      <Button title="Sign out" variant="danger" onPress={() => supabase.auth.signOut()} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  name: { fontSize: 20, fontWeight: '700', color: colors.text },
  email: { fontSize: 14, color: colors.muted },
  hint: { fontSize: 14, color: colors.muted, lineHeight: 20 },
  listing: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.md,
  },
  listingTitle: { fontSize: 16, fontWeight: '600', color: colors.text },
  state: { fontSize: 13, fontWeight: '600', color: colors.primary },
  reason: { fontSize: 13, color: colors.danger, marginTop: 2 },
  appeal: { fontSize: 13, color: colors.primary, textDecorationLine: 'underline', marginTop: 4 },
});
