import { useLocalSearchParams, useRouter } from 'expo-router';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Notice, SectionTitle } from '../../../../src/components/ui';
import { ROLE_EXPLAINED, ROLE_LABELS, roleCan } from '../../../../src/domain/business';
import { useBusinessAccess } from '../../../../src/features/business/useAccess';
import { colors, spacing } from '../../../../src/theme';

export default function BusinessDashboard() {
  const router = useRouter();
  const { id } = useLocalSearchParams<{ id: string }>();
  const { role, name, slug, loading } = useBusinessAccess(id);
  const go = (path: string) => router.push({ pathname: path as any, params: { id } });

  if (loading) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  if (!role) return <View style={styles.center}><Notice tone="error">You are not part of this business.</Notice></View>;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Text style={styles.title}>{name}</Text>
      <Text style={styles.text}>You are {ROLE_LABELS[role].toLowerCase()}. {ROLE_EXPLAINED[role]}</Text>

      <SectionTitle>Every day</SectionTitle>
      {roleCan(role, 'manage_orders') ? <Button title="Orders" onPress={() => go('/business/manage/[id]/orders')} /> : null}
      {roleCan(role, 'manage_listings') ? <Button title="Listings and prices" variant="secondary" onPress={() => router.push({ pathname: '/seller/listings', params: { business: String(id) } })} /> : null}
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
