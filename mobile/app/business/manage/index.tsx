import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../../src/auth/AuthProvider';
import { Button, Notice, SectionTitle } from '../../../src/components/ui';
import { ROLE_LABELS } from '../../../src/domain/business';
import { fetchMyInvitations, fetchMyMemberships, type MyMembership } from '../../../src/features/business/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

export default function MyBusinesses() {
  const router = useRouter();
  const { userId } = useAuth();
  const [items, setItems] = useState<MyMembership[]>([]);
  const [invites, setInvites] = useState(0);
  const [error, setError] = useState('');

  useFocusEffect(
    useCallback(() => {
      if (!userId) return;
      Promise.all([fetchMyMemberships(userId), fetchMyInvitations()])
        .then(([m, i]) => {
          setItems(m);
          setInvites(i.length);
          setError('');
        })
        .catch((e) => setError(friendlyError(e)));
    }, [userId]),
  );

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.title}>Business tools</Text>
      {invites > 0 ? (
        <>
          <Notice>{`You have ${invites} team invitation${invites === 1 ? '' : 's'} waiting.`}</Notice>
          <Button title="See invitations" onPress={() => router.push('/business/invitations')} />
        </>
      ) : null}

      <SectionTitle>Your businesses</SectionTitle>
      {items.length === 0 ? <Text style={styles.text}>You are not part of a business yet. Add one, or ask the owner to invite your email address.</Text> : null}
      {items.map((b) => (
        <View key={b.businessId} style={styles.card}>
          <Text style={styles.name}>{b.name}</Text>
          <Text style={styles.text}>{ROLE_LABELS[b.role]}</Text>
          <Button title="Open" onPress={() => router.push({ pathname: '/business/manage/[id]', params: { id: b.businessId } })} />
          <Button title="Business numbers" variant="secondary" onPress={() => router.push({ pathname: '/analytics', params: { business: b.businessId } })} />
          <Button title="View public page" variant="secondary" onPress={() => router.push({ pathname: '/business/[slug]', params: { slug: b.slug } })} />
        </View>
      ))}
      <Button title="Add a business" variant="secondary" onPress={() => router.push('/verify/business')} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  name: { fontSize: 17, fontWeight: '600', color: colors.text },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
});
