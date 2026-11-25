import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Field, Notice, SectionTitle } from '../../src/components/ui';
import { ROLE_LABELS, cleanTotpCode, staffAccessStep, type AdminRole, type StaffStep } from '../../src/domain/admin';
import { staffMenu } from '../../src/domain/staffMenu';
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
      <View style={styles.header}>
        <Text style={styles.title}>Staff tools</Text>
        <View style={styles.roleRow}>
          {roles.map((r) => (
            <View key={r} style={styles.rolePill}>
              <Text style={styles.rolePillText}>{ROLE_LABELS[r]}</Text>
            </View>
          ))}
        </View>
      </View>

      {staffMenu(roles).map((section) => (
        <View key={section.title} style={styles.section}>
          <Text style={styles.sectionTitle}>{section.title}</Text>
          <View style={styles.group}>
            {section.items.map((item, i) => (
              <Pressable
                key={item.key}
                accessibilityRole="button"
                onPress={() => router.push(item.href as never)}
                style={({ pressed }) => [styles.row, i > 0 && styles.rowDivider, pressed && { backgroundColor: colors.primarySoft }]}
              >
                <View style={{ flex: 1 }}>
                  <Text style={styles.rowTitle}>{item.title}</Text>
                  <Text style={styles.rowNote}>{item.note}</Text>
                </View>
                <Text style={styles.chevron}>›</Text>
              </Pressable>
            ))}
          </View>
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, padding: spacing.xl, gap: spacing.md, justifyContent: 'center', backgroundColor: colors.background },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  header: { gap: spacing.sm },
  roleRow: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  rolePill: { backgroundColor: colors.primarySoft, borderRadius: 999, paddingHorizontal: 12, paddingVertical: 4 },
  rolePillText: { fontSize: 13, fontWeight: '700', color: colors.primaryDark },
  section: { gap: spacing.sm },
  sectionTitle: { fontSize: 13, fontWeight: '700', letterSpacing: 0.6, textTransform: 'uppercase', color: colors.muted },
  group: { backgroundColor: colors.surface, borderRadius: 12, borderWidth: 1, borderColor: colors.border, overflow: 'hidden' },
  row: { flexDirection: 'row', alignItems: 'center', paddingVertical: 14, paddingHorizontal: spacing.md, gap: spacing.sm },
  rowDivider: { borderTopWidth: 1, borderTopColor: colors.border },
  rowTitle: { fontSize: 16, fontWeight: '600', color: colors.text },
  rowNote: { fontSize: 13, lineHeight: 18, color: colors.muted, marginTop: 2 },
  chevron: { fontSize: 24, color: colors.muted },
  secretBox: { gap: spacing.sm, padding: spacing.md, borderRadius: 12, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  secret: { fontSize: 18, fontWeight: '700', letterSpacing: 1, color: colors.text },
});
