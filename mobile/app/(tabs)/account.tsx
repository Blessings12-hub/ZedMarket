import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, Share, StyleSheet, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Notice } from '../../src/components/ui';
import { canShareSellerProfile } from '../../src/domain/sellerAccess';
import { sellerLink, sellerShareMessage, webBase } from '../../src/domain/share';
import { fetchHub, type HubProfile } from '../../src/features/account-hub/api';
import {
  AccountHeader,
  AccountQuickActions,
  AccountSection,
  AccountTypeSwitcher,
  BusinessSummary,
  SellerSummary,
} from '../../src/features/account-hub/components';
import { buildHub, validContext, type HubFacts, type HubItem } from '../../src/features/account-hub/hub';
import { watchNotifications, countUnreadNotifications } from '../../src/features/notifications/api';
import { disablePushForThisPhone } from '../../src/features/notifications/push';
import { setSellingAccess } from '../../src/features/seller/status';
import { friendlyError } from '../../src/lib/errors';
import { supabase } from '../../src/lib/supabase';
import { colors, spacing } from '../../src/theme';

// The Profile tab. It organises screens that already exist; each row opens the existing feature.
export default function AccountHub() {
  const router = useRouter();
  const { userId, session } = useAuth();
  const [profile, setProfile] = useState<HubProfile | null>(null);
  const [facts, setFacts] = useState<Omit<HubFacts, 'context'> | null>(null);
  const [context, setContext] = useState<string>('personal');
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      const hub = await fetchHub(userId);
      setProfile(hub.profile);
      setFacts(hub.facts);
      // Tell the bottom bar and the selling screens what the team has decided about this person.
      setSellingAccess({ status: hub.facts.sellerStatus, hasBusiness: hub.facts.businesses.length > 0 });
      setContext((c) => validContext(c, hub.facts.businesses));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [userId]);

  useFocusEffect(
    useCallback(() => {
      void load();
      if (!userId) return undefined;
      return watchNotifications(userId, () =>
        void countUnreadNotifications().then((n) => setFacts((f) => (f ? { ...f, unreadNotifications: n } : f))).catch(() => undefined),
      );
    }, [load, userId]),
  );

  const open = (item: HubItem) => router.push(item.href as never);

  async function shareProfile() {
    if (!userId || !profile) return;
    const link = sellerLink(webBase(process.env.EXPO_PUBLIC_WEB_URL), userId);
    try {
      await Share.share({ message: sellerShareMessage({ name: profile.displayName, link }) });
    } catch {
      /* closing the share sheet is not an error */
    }
  }

  if (!profile || !facts) {
    return (
      <View style={styles.center}>
        {error ? <Notice tone="error">{error}</Notice> : <ActivityIndicator color={colors.primary} />}
      </View>
    );
  }

  const sections = buildHub({ ...facts, context });
  const selected = facts.businesses.find((b) => b.id === context);
  const isSeller = facts.sellerStatus === 'active';
  // Everything about selling sits together at the bottom, so the business switcher goes with it.
  const sellingKeys = ['selling', 'business', 'become-seller'];
  const firstSellingKey = sections.find((x) => sellingKeys.includes(x.key))?.key;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}

      <AccountHeader
        profile={profile}
        email={session?.user.email}
        emailConfirmedAt={session?.user.email_confirmed_at}
        onEdit={() => router.push('/profile/edit')}
        onShare={canShareSellerProfile(facts.sellerStatus) ? shareProfile : undefined}
        isSeller={isSeller}
      />
      {profile.state !== 'active' ? (
        <>
          <Notice tone="warning">
            {profile.state === 'suspended'
              ? 'Your account is suspended.'
              : isSeller
                ? 'Your account is restricted, so you cannot post new listings.'
                : 'Your account is restricted.'}
          </Notice>
          <Button title="Appeal this decision" variant="secondary" onPress={() => router.push({ pathname: '/appeal', params: { targetType: 'user', targetId: userId } })} />
        </>
      ) : null}

      <AccountQuickActions
        actions={[
          { key: 'cart', label: 'Cart', onPress: () => router.push('/(tabs)/cart') },
          { key: 'orders', label: 'Orders', onPress: () => router.push('/orders'), badge: facts.activeBuying > 0 ? `${facts.activeBuying} open` : undefined },
          { key: 'saved', label: 'Saved', onPress: () => router.push('/saved') },
          // Buyers get Messages here; approved sellers get their listings (Messages is already a tab).
          isSeller
            ? { key: 'listings', label: 'Listings', onPress: () => router.push('/account/listings'), badge: facts.listings.live > 0 ? `${facts.listings.live} live` : undefined }
            : { key: 'messages', label: 'Messages', onPress: () => router.push('/(tabs)/messages') },
        ]}
      />

      {sections.map((section) => (
        <View key={section.key} style={{ gap: spacing.sm }}>
          {section.key === firstSellingKey ? <AccountTypeSwitcher businesses={facts.businesses} value={context} onChange={setContext} /> : null}
          {section.key === 'selling' && isSeller ? <SellerSummary {...facts.listings} /> : null}
          {section.key === 'business' && selected ? <BusinessSummary business={selected} /> : null}
          <AccountSection section={section} onOpen={open} />
        </View>
      ))}

      <Button
        title="Sign out"
        variant="danger"
        onPress={async () => {
          await disablePushForThisPhone();
          await supabase.auth.signOut();
        }}
      />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl * 2 },
  center: { flex: 1, justifyContent: 'center', padding: spacing.lg, backgroundColor: colors.background },
});
