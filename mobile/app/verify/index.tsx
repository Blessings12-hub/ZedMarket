import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Notice, SectionTitle } from '../../src/components/ui';
import { reviewStateLabel, type ReviewState } from '../../src/domain/trust';
import { fetchMyBusinesses, fetchMyIdentityRequest, type MyBusiness, type VerificationRequest } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

const BUSINESS_STATE: Record<MyBusiness['status'], ReviewState> = {
  unverified: 'none',
  pending: 'pending',
  verified: 'approved',
  rejected: 'rejected',
};

export default function VerifyHome() {
  const router = useRouter();
  const { userId } = useAuth();
  const [identity, setIdentity] = useState<VerificationRequest | null>(null);
  const [businesses, setBusinesses] = useState<MyBusiness[]>([]);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      const [id, biz] = await Promise.all([fetchMyIdentityRequest(userId), fetchMyBusinesses(userId)]);
      setIdentity(id);
      setBusinesses(biz);
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

  const idState: ReviewState = identity?.state ?? 'none';

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Notice>
        Verified sellers get a badge that buyers can see. Your documents are only seen by our verification team, and the files are deleted after
        the check.
      </Notice>

      <SectionTitle>You</SectionTitle>
      <View style={styles.card}>
        <Text style={styles.title}>Identity check</Text>
        <Text style={styles.text}>{reviewStateLabel(idState)}</Text>
        {identity?.state === 'rejected' && identity.note ? <Text style={styles.reason}>{identity.note}</Text> : null}
        {idState === 'none' || idState === 'rejected' ? (
          <Button title={idState === 'rejected' ? 'Try again' : 'Start the check'} onPress={() => router.push('/verify/identity')} />
        ) : null}
      </View>

      <SectionTitle>Your businesses</SectionTitle>
      {businesses.map((b) => (
        <View key={b.id} style={styles.card}>
          <Text style={styles.title}>{b.name}</Text>
          <Text style={styles.text}>{reviewStateLabel(BUSINESS_STATE[b.status])}</Text>
          {b.status !== 'verified' ? (
            <Button
              title={b.status === 'pending' ? 'See details' : 'Submit registration details'}
              variant="secondary"
              onPress={() => router.push({ pathname: '/verify/business', params: { businessId: b.id } })}
            />
          ) : null}
        </View>
      ))}
      <Button title="Add a business" variant="secondary" onPress={() => router.push('/verify/business')} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  title: { fontSize: 17, fontWeight: '600', color: colors.text },
  text: { fontSize: 15, color: colors.muted },
  reason: { fontSize: 14, color: colors.danger },
});
