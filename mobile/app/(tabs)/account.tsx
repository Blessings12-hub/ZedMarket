import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, Share, StyleSheet, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Notice } from '../../src/components/ui';
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

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}

      <AccountHeader
        profile={profile}
        email={session?.user.email}
        emailConfirmedAt={session?.user.email_confirmed_at}
        onEdit={() => router.push('/profile/edit')}
        onShare={shareProfile}
      />
      {profile.state !== 'active' ? (
        <>
          <Notice tone="warning">
            {profile.state === 'suspended' ? 'Your account is suspended.' : 'Your account is restricted, so you cannot post new listings.'}
          </Notice>
          <Button title="Appeal this decision" variant="secondary" onPress={() => router.push({ pathname: '/appeal', params: { targetType: 'user', targetId: userId } })} />
        </>
      ) : null}
      {profile.level === 'unverified' ? <Notice>Verified sellers get a badge buyers can see. Open "Seller verification" below to start.</Notice> : null}

      <AccountTypeSwitcher businesses={facts.businesses} value={context} onChange={setContext} />

      <AccountQuickActions
        actions={[
          { key: 'orders', label: 'Orders', onPress: () => router.push('/orders'), badge: facts.activeBuying > 0 ? `${facts.activeBuying} open` : undefined },
          { key: 'listings', label: 'Listings', onPress: () => router.push('/account/listings'), badge: facts.listings.live > 0 ? `${facts.listings.live} live` : undefined },
          { key: 'saved', label: 'Saved', onPress: () => router.push('/saved') },
          { key: 'messages', label: 'Messages', onPress: () => router.push('/(tabs)/messages') },
        ]}
      />

      {sections.map((section) => (
        <View key={section.key} style={{ gap: spacing.sm }}>
          {section.key === 'selling' ? <SellerSummary {...facts.listings} /> : null}
          {section.key === 'business' && selected ? <BusinessSummary business={selected} /> : null}
          <AccountSection section={section} onOpen={open} />
        </View>
      ))}

      {facts.businesses.length === 0 ? (
        <AccountSection
          section={{ key: 'add-business', title: 'Business centre', items: [{ key: 'add', title: 'Add a business', subtitle: 'Register a business, or ask an owner to invite your email', href: { pathname: '/business/manage' } }] }}
          onOpen={open}
        />
      ) : null}

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
