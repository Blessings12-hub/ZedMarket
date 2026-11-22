import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Field, Notice, SectionTitle } from '../../src/components/ui';
import {
  canHandleReports,
  canManageTeam,
  canModerate,
  canSeeTrustAudit,
  canSupport,
  cleanTotpCode,
  staffAccessStep,
  type AdminRole,
  type StaffStep,
} from '../../src/domain/admin';
import { confirmCode, fetchAssurance, fetchMyRoles, startEnrolment, verifiedFactorId } from '../../src/features/admin/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, spacing } from '../../src/theme';

export default function AdminHome() {
  const router = useRouter();
  const { userId } = useAuth();

  const [roles, setRoles] = useState<AdminRole[]>([]);
  const [step, setStep] = useState<StaffStep | null>(null);
  const [factorId, setFactorId] = useState<string | null>(null);
  const [secret, setSecret] = useState('');
  const [code, setCode] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      const myRoles = await fetchMyRoles(userId);
      const level = await fetchAssurance();
      setRoles(myRoles);
      setStep(staffAccessStep(myRoles, level.currentLevel, level.nextLevel));
      if (level.nextLevel === 'aal2') setFactorId(await verifiedFactorId());
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

  async function beginEnrolment() {
    setBusy(true);
    setError('');
    try {
      const result = await startEnrolment();
      setFactorId(result.factorId);
      setSecret(result.secret);
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  async function submitCode() {
    if (!factorId) return;
    setBusy(true);
    setError('');
    try {
      await confirmCode(factorId, cleanTotpCode(code));
      setCode('');
      setSecret('');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (step === null) {
    return (
      <View style={styles.center}>
        {error ? <Notice tone="error">{error}</Notice> : <ActivityIndicator color={colors.primary} />}
      </View>
    );
  }

  if (step === 'not_staff') {
    return (
      <View style={styles.center}>
        <Text style={styles.title}>Staff only</Text>
        <Text style={styles.text}>This account has no staff role.</Text>
      </View>
    );
  }

  if (step === 'enrol' || step === 'verify') {
    const enrolling = step === 'enrol';
    const codeReady = cleanTotpCode(code).length === 6;
    return (
      <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        {error ? <Notice tone="error">{error}</Notice> : null}
        <Text style={styles.title}>{enrolling ? 'Set up two-factor sign-in' : 'Enter your sign-in code'}</Text>
        <Text style={styles.text}>
          {enrolling
            ? 'Staff tools stay locked until two-factor sign-in is on. Use an authenticator app such as Google Authenticator.'
            : 'Open your authenticator app and type the 6-digit code for ZedMarket.'}
        </Text>

        {enrolling && !secret ? <Button title="Start setup" onPress={beginEnrolment} loading={busy} /> : null}

        {enrolling && secret ? (
          <View style={styles.secretBox}>
            <Text style={styles.text}>In your authenticator app, choose to add an account by typing a key, then enter this key:</Text>
            <Text selectable style={styles.secret}>
              {secret}
            </Text>
            <Text style={styles.text}>Then type the 6-digit code the app shows.</Text>
          </View>
        ) : null}

        {(!enrolling || secret) && factorId ? (
          <>
            <Field
              label="6-digit code"
              value={code}
              onChangeText={(v) => setCode(cleanTotpCode(v))}
              keyboardType="number-pad"
              maxLength={6}
              autoComplete="one-time-code"
            />
            <Button title="Confirm" onPress={submitCode} loading={busy} disabled={!codeReady} />
          </>
        ) : null}
      </ScrollView>
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.title}>Staff tools</Text>
      <Text style={styles.text}>Your roles: {roles.join(', ')}</Text>

      {canModerate(roles) ? (
        <>
          <SectionTitle>Moderation</SectionTitle>
          <Button title="Listings waiting for review" onPress={() => router.push('/admin/listings')} />
          <Button title="Appeals" variant="secondary" onPress={() => router.push('/admin/appeals')} />
          <Button title="Risk flags" variant="secondary" onPress={() => router.push('/admin/flags')} />
        </>
      ) : null}

      {canHandleReports(roles) ? (
        <>
          <SectionTitle>Reports</SectionTitle>
          <Button title="Open reports" onPress={() => router.push('/admin/reports')} />
        </>
      ) : null}

      {canSupport(roles) ? (
        <>
          <SectionTitle>Support</SectionTitle>
          <Button title="Verification requests" onPress={() => router.push('/admin/verifications')} />
          <Button title="Disputes" variant="secondary" onPress={() => router.push('/admin/disputes')} />
        </>
      ) : null}

      {canSeeTrustAudit(roles) ? (
        <>
          <SectionTitle>Users and trust</SectionTitle>
          <Button title="User & Trust Management" variant="secondary" onPress={() => router.push('/trust')} />
        </>
      ) : null}

      {canManageTeam(roles) ? (
        <>
          <SectionTitle>Administration</SectionTitle>
          <Button title="Staff team" onPress={() => router.push('/admin/team')} />
          <Button title="Audit log" variant="secondary" onPress={() => router.push('/admin/audit')} />
        </>
      ) : null}

      {!canModerate(roles) && !canHandleReports(roles) && !canSupport(roles) && !canManageTeam(roles) ? (
        <Notice>The finance role has no screens yet, because payments come in a later release.</Notice>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, padding: spacing.xl, gap: spacing.md, justifyContent: 'center', backgroundColor: colors.background },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  secretBox: { gap: spacing.sm, padding: spacing.md, borderRadius: 12, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  secret: { fontSize: 18, fontWeight: '700', letterSpacing: 1, color: colors.text },
});
