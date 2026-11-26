import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useCallback, useState } from 'react';

import { useAuth } from '../../../../src/auth/AuthProvider';
import { DangerConfirm } from '../../../../src/components/DangerConfirm';
import { Button, Notice, SectionTitle } from '../../../../src/components/ui';
import { ROLE_EXPLAINED, ROLE_LABELS, roleCan } from '../../../../src/domain/business';
import { BUSINESS_CLOSE } from '../../../../src/domain/closeAccount';
import { closeBusiness } from '../../../../src/features/business/api';
import { attentionTiles, salesSummary, setupChecklist } from '../../../../src/features/business/dashboard';
import { fetchBusinessDashboard, type BusinessDashboardData } from '../../../../src/features/business/dashboardApi';
import { AttentionTiles, SalesCard, SetupChecklist } from '../../../../src/features/business/dashboardView';
import { useBusinessAccess } from '../../../../src/features/business/useAccess';
import { refreshSellingAccess } from '../../../../src/features/seller/status';
import { friendlyError } from '../../../../src/lib/errors';
import { colors, spacing } from '../../../../src/theme';

export default function BusinessDashboard() {
  const router = useRouter();
  const { id } = useLocalSearchParams<{ id: string }>();
  const { role, name, slug, loading } = useBusinessAccess(id);
  const { userId } = useAuth();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [dash, setDash] = useState<BusinessDashboardData | null>(null);

  async function deleteBusiness() {
    setBusy(true);
    setError('');
    try {
      await closeBusiness(String(id));
      if (userId) await refreshSellingAccess(userId);
      router.replace('/(tabs)/account');
    } catch (e) {
      setError(friendlyError(e));
      setBusy(false);
    }
  }
  useFocusEffect(
    useCallback(() => {
      if (!role || !id) return undefined;
      let cancelled = false;
      void fetchBusinessDashboard(String(id), slug, role).then((d) => { if (!cancelled) setDash(d); }).catch((e) => console.warn('[business dashboard]', e));
      return () => { cancelled = true; };
    }, [role, id, slug]),
  );
  const go = (path: string) => router.push({ pathname: path as any, params: { id } });

  if (loading) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  if (!role) return <View style={styles.center}><Notice tone="error">You are not part of this business.</Notice></View>;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Text style={styles.title}>{name}</Text>
      <Text style={styles.text}>You are {ROLE_LABELS[role].toLowerCase()}. {ROLE_EXPLAINED[role]}</Text>

      {dash ? (
        <>
          {dash.failed.length > 0 ? <Notice tone="warning">{`Some numbers could not be loaded (${dash.failed.join(', ')}). Open the screen again to retry.`}</Notice> : null}
          <SectionTitle>Today</SectionTitle>
          <AttentionTiles tiles={attentionTiles(role, dash.facts)} onOpen={(t) => go(t.href === 'orders' ? '/business/manage/[id]/orders' : '/business/manage/[id]/inventory')} />
          {(() => {
            const c = setupChecklist(role, dash.setup);
            if (c.complete) return null;
            return (
              <SetupChecklist
                {...c}
                onOpen={(s) => {
                  if (s.key === 'branch') go('/business/manage/[id]/branches');
                  else if (s.key === 'catalogue') go('/business/manage/[id]/catalogues');
                  else if (s.key === 'products') router.push('/(tabs)/sell');
                  else router.push('/verify/business');
                }}
              />
            );
          })()}
          {(() => {
            const sales = salesSummary(role, dash.analytics);
            return sales ? <SalesCard sales={sales} onOpen={() => go('/business/manage/[id]/analytics')} /> : null;
          })()}
        </>
      ) : <ActivityIndicator color={colors.primary} />}

      <SectionTitle>Every day</SectionTitle>
      {roleCan(role, 'manage_orders') ? <Button title="Orders" onPress={() => go('/business/manage/[id]/orders')} /> : null}
      {roleCan(role, 'manage_listings') ? <Button title="Listings and prices" variant="secondary" onPress={() => router.push({ pathname: '/selling/listings', params: { business: String(id) } })} /> : null}
      {roleCan(role, 'manage_inventory') && roleCan(role, 'manage_listings') ? <Button title="Import products" variant="secondary" onPress={() => go('/business/manage/[id]/imports')} /> : null}
      {roleCan(role, 'manage_inventory') ? <Button title="Stock" variant="secondary" onPress={() => go('/business/manage/[id]/inventory')} /> : null}
      <Button title="Post a business listing" variant="secondary" onPress={() => router.push('/(tabs)/sell')} />

      {roleCan(role, 'manage_branches') || roleCan(role, 'manage_catalogues') ? (
        <>
          <SectionTitle>Shop setup</SectionTitle>
          {roleCan(role, 'manage_branches') ? <Button title="Branches" variant="secondary" onPress={() => go('/business/manage/[id]/branches')} /> : null}
          {roleCan(role, 'manage_branches') ? <Button title="Where we deliver" variant="secondary" onPress={() => router.push({ pathname: '/delivery/areas', params: { businessId: id } })} /> : null}
          {roleCan(role, 'manage_catalogues') ? <Button title="Catalogues" variant="secondary" onPress={() => go('/business/manage/[id]/catalogues')} /> : null}
          <Button title="View public page" variant="secondary" onPress={() => router.push({ pathname: '/business/[slug]', params: { slug } })} />
        </>
      ) : null}

      {roleCan(role, 'view_analytics') ? (
        <>
          <SectionTitle>Numbers</SectionTitle>
          <Button title="Analytics" variant="secondary" onPress={() => go('/business/manage/[id]/analytics')} />
        </>
      ) : null}

      {roleCan(role, 'view_team') ? (
        <>
          <SectionTitle>People</SectionTitle>
          <Button title={roleCan(role, 'manage_team') ? 'Team and invitations' : 'Team'} variant="secondary" onPress={() => go('/business/manage/[id]/team')} />
        </>
      ) : null}

      {role === 'owner' ? (
        <>
          <SectionTitle>{BUSINESS_CLOSE.heading}</SectionTitle>
          <DangerConfirm copy={BUSINESS_CLOSE} busy={busy} error={error} onConfirm={deleteBusiness} />
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  center: { flex: 1, padding: spacing.xl, justifyContent: 'center', backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
});
