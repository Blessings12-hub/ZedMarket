import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { RefreshControl, ScrollView, StyleSheet, View } from 'react-native';

import { useAuth } from '../src/auth/AuthProvider';
import { Button, Notice } from '../src/components/ui';
import { fetchHub } from '../src/features/account-hub/api';
import { AccountSection, AccountTypeSwitcher, BusinessSummary, HubSkeleton, SellerSummary, SellingBanner } from '../src/features/account-hub/components';
import { sellingBanner } from '../src/features/account-hub/dashboard';
import { buildSellCentre, validContext, type HubFacts, type HubItem } from '../src/features/account-hub/hub';
import { setSellingAccess } from '../src/features/seller/status';
import { friendlyError } from '../src/lib/errors';
import { colors, spacing } from '../src/theme';

// Everything about selling and businesses, kept off the buyer's hub. A buyer sees an invitation; an approved seller sees
// their tools; a business member sees the business centre. The database still decides what anyone may do.
export default function SellHub() {
  const router = useRouter();
  const { userId } = useAuth();
  const [facts, setFacts] = useState<Omit<HubFacts, 'context'> | null>(null);
  const [context, setContext] = useState('personal');
  const [error, setError] = useState('');
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      const hub = await fetchHub(userId);
      setFacts(hub.facts);
      setSellingAccess({ status: hub.facts.sellerStatus, hasBusiness: hub.facts.businesses.length > 0 });
      setContext((c) => validContext(c, hub.facts.businesses));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [userId]);

  useFocusEffect(useCallback(() => { void load(); }, [load]));

  if (!facts) {
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
  const sections = buildSellCentre({ ...facts, context }).filter((x) => !(banner && x.key === 'become-seller'));
  const selected = facts.businesses.find((b) => b.id === context);
  const open = (item: HubItem) => router.push(item.href as never);

  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={styles.content}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); void load().finally(() => setRefreshing(false)); }} tintColor={colors.primary} />}
    >
      {error ? <Notice tone="error">{error}</Notice> : null}
      {facts.sellerApplicationError ? <Notice tone="warning">{`Your seller application status could not be loaded. ${facts.sellerApplicationError}`}</Notice> : null}
      {banner ? <SellingBanner banner={banner} onOpen={(href) => router.push(href as never)} /> : null}
      <AccountTypeSwitcher businesses={facts.businesses} value={context} onChange={setContext} />
      {sections.map((section) => (
        <View key={section.key} style={{ gap: spacing.sm }}>
          {section.key === 'selling' && facts.sellerStatus === 'active' ? <SellerSummary {...facts.listings} /> : null}
          {section.key === 'business' && selected ? <BusinessSummary business={selected} /> : null}
          <AccountSection section={section} onOpen={open} />
        </View>
      ))}
      {sections.length === 0 && !banner ? <Notice>Nothing to show here yet.</Notice> : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl * 2 },
  center: { flex: 1, justifyContent: 'center', padding: spacing.lg, backgroundColor: colors.background },
});
