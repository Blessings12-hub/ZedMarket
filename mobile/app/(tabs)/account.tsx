import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { RefreshControl, ScrollView, Share, StyleSheet, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Notice } from '../../src/components/ui';
import { SELLER_CLOSE } from '../../src/domain/closeAccount';
import { canShareSellerProfile } from '../../src/domain/sellerAccess';
import { sellerLink, sellerShareMessage, webBase } from '../../src/domain/share';
import { fetchHub, type HubProfile } from '../../src/features/account-hub/api';
import {
  AccountSection,
  AccountTypeSwitcher,
  BusinessSummary,
  HubHeader,
  HubSkeleton,
  NudgeCard,
  OrderStrip,
  SellerSummary,
  SellingBanner,
  TilesGrid,
} from '../../src/features/account-hub/components';
import { orderStrip, profileNudge, quickTiles, sellingBanner, type StripOrder } from '../../src/features/account-hub/dashboard';
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
  const { notice } = useLocalSearchParams<{ notice?: string }>();
  const { userId, session } = useAuth();
  const [profile, setProfile] = useState<HubProfile | null>(null);
  const [facts, setFacts] = useState<Omit<HubFacts, 'context'> | null>(null);
  const [context, setContext] = useState<string>('personal');
  const [orders, setOrders] = useState<StripOrder[]>([]);
  const [error, setError] = useState('');
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      const hub = await fetchHub(userId);
      setProfile(hub.profile);
      setFacts(hub.facts);
      setOrders(hub.orders);
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
        {error ? (
          <>
            <Notice tone="error">{error}</Notice>
            <Button title="Try again" variant="secondary" onPress={() => void load()} />
          </>
        ) : <HubSkeleton />}
      </View>
    );
  }

  const banner = sellingBanner(facts);
  const nudge = profileNudge({
    emailConfirmed: !!session?.user.email_confirmed_at,
    hasAvatar: !!profile.avatarPath,
    hasBio: profile.bio.trim().length > 0,
  });
  const strip = orderStrip(orders);
  // The selling invitation replaces the plain "Sell on ZedMarket" list for buyers; it is the same two doors, shown better.
  const sections = buildHub({ ...facts, context }).filter((x) => !(banner && x.key === 'become-seller'));
  const selected = facts.businesses.find((b) => b.id === context);
  const isSeller = facts.sellerStatus === 'active';
  // Everything about selling sits together at the bottom, so the business switcher goes with it.
  const sellingKeys = ['selling', 'business', 'become-seller'];
  const firstSellingKey = sections.find((x) => sellingKeys.includes(x.key))?.key;

  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={styles.content}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); void load().finally(() => setRefreshing(false)); }} tintColor={colors.primary} />}
    >
      {error ? <Notice tone="error">{error}</Notice> : null}
      {notice === 'seller_closed' ? <Notice>{SELLER_CLOSE.done}</Notice> : null}
      {facts.sellerApplicationError ? <Notice tone="warning">{`Your seller application status could not be loaded. ${facts.sellerApplicationError}`}</Notice> : null}

      <HubHeader
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

      <TilesGrid tiles={quickTiles(facts)} onOpen={(t) => router.push(t.href as never)} />

      <OrderStrip items={strip.items} more={strip.more} onOpen={() => router.push('/orders')} />

      {nudge ? <NudgeCard nudge={nudge} onPress={() => router.push(nudge.href as never)} /> : null}

      {banner ? <SellingBanner banner={banner} onOpen={(href) => router.push(href as never)} /> : null}

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
