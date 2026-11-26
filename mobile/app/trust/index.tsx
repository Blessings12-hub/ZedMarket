import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Notice, SectionTitle } from '../../src/components/ui';
import { canReadTrust, canSeeTrustAudit, type AdminRole } from '../../src/domain/admin';
import { fetchAssurance, fetchMyRoles } from '../../src/features/admin/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, spacing } from '../../src/theme';

// The home of User & Trust Management. It is its own section: the Staff tools page
// stays about the staff team and day-to-day queues.
export default function TrustHome() {
  const router = useRouter();
  const { userId } = useAuth();
  const [roles, setRoles] = useState<AdminRole[] | null>(null);
  const [twoFactor, setTwoFactor] = useState(false);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      const [myRoles, level] = await Promise.all([fetchMyRoles(userId), fetchAssurance()]);
      setRoles(myRoles);
      setTwoFactor(level.currentLevel === 'aal2');
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

  if (!roles && !error) {
    return (
      <View style={styles.center}>
        <ActivityIndicator color={colors.primary} />
      </View>
    );
  }

  if (!roles || !canSeeTrustAudit(roles)) {
    return (
      <View style={styles.center}>
        {error ? <Notice tone="error">{error}</Notice> : null}
        <Text style={styles.title}>Staff only</Text>
        <Text style={styles.text}>This section is for support and moderation staff.</Text>
      </View>
    );
  }

  if (!twoFactor) {
    return (
      <View style={styles.center}>
        <Text style={styles.title}>Two-factor sign-in needed</Text>
        <Text style={styles.text}>This section holds personal documents, so it stays locked until you have signed in with your authenticator code.</Text>
        <Button title="Go to Staff tools to sign in" onPress={() => router.push('/admin')} />
      </View>
    );
  }

  const reader = canReadTrust(roles);

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.title}>User & Trust Management</Text>
      <Text style={styles.text}>Your roles: {roles.join(', ')}</Text>

      {reader ? (
        <>
          <SectionTitle>Seller and business verification</SectionTitle>
          <Button title="Workload, deadlines and document access" onPress={() => router.push('/trust/workload')} />
          <Button title="Repeated photos" variant="secondary" onPress={() => router.push('/trust/photo-flags')} />
          <Button title="Seller applications and queues" onPress={() => router.push('/trust/seller-applications')} />
          <Button title="Business applications" onPress={() => router.push('/trust/business-applications')} />

          <SectionTitle>Identity and business checks (earlier flow)</SectionTitle>
          <Button title="Pending applications" onPress={() => router.push({ pathname: '/trust/applications', params: { status: 'pending' } })} />
          <Button title="Rejected applications" variant="secondary" onPress={() => router.push({ pathname: '/trust/applications', params: { status: 'rejected' } })} />

          <SectionTitle>People</SectionTitle>
          <Button title="Verified users" variant="secondary" onPress={() => router.push({ pathname: '/trust/users', params: { filter: 'verified' } })} />
          <Button title="Suspended accounts" variant="secondary" onPress={() => router.push({ pathname: '/trust/users', params: { filter: 'suspended' } })} />
          <Button title="Restricted accounts" variant="secondary" onPress={() => router.push({ pathname: '/trust/users', params: { filter: 'restricted' } })} />
          <Button title="Find any user" variant="secondary" onPress={() => router.push({ pathname: '/trust/users', params: { filter: 'all' } })} />
        </>
      ) : null}

      <SectionTitle>Accountability</SectionTitle>
      <Button title="Audit trail" variant="secondary" onPress={() => router.push('/trust/audit')} />
      <Notice>
        Opening a document is written to the audit trail with your name. Support and moderators see the entries for this section;
        technical admins see everything.
      </Notice>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, padding: spacing.xl, gap: spacing.md, justifyContent: 'center', backgroundColor: colors.background },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
});
