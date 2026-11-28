import { useRouter } from 'expo-router';
import { useState } from 'react';
import { ScrollView, StyleSheet, Text } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { DangerConfirm } from '../../src/components/DangerConfirm';
import { Button, Field, Notice, SectionTitle } from '../../src/components/ui';
import { ACCOUNT_DELETE } from '../../src/domain/closeAccount';
import { deleteMyAccount } from '../../src/features/launch/api';
import { supabase } from '../../src/lib/supabase';
import { changePassword, resendConfirmation, sendResetEmail, signOutOtherDevices } from '../../src/features/account-hub/api';
import { emailStatus, passwordProblem } from '../../src/features/account-hub/hub';
import { friendlyError } from '../../src/lib/errors';
import { colors, spacing } from '../../src/theme';

export default function Security() {
  const { session } = useAuth();
  const router = useRouter();
  const [deleteError, setDeleteError] = useState('');
  const [deleting, setDeleting] = useState(false);
  const email = session?.user.email ?? '';
  const confirmed = emailStatus(session?.user.email_confirmed_at) === 'verified';
  const [next, setNext] = useState('');
  const [again, setAgain] = useState('');
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [done, setDone] = useState('');

  async function run(name: string, job: () => Promise<void>, ok: string) {
    setBusy(name); setError(''); setDone('');
    try { await job(); setDone(ok); } catch (e) { setError(friendlyError(e)); } finally { setBusy(''); }
  }

  async function deleteAccount() {
    setDeleting(true); setDeleteError('');
    try {
      await deleteMyAccount();
      // The account can no longer sign in, so end this session on the phone too.
      await supabase.auth.signOut().catch(() => undefined);
      router.replace('/sign-in');
    } catch (e) {
      setDeleteError(friendlyError(e));
    } finally {
      setDeleting(false);
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {done ? <Notice>{done}</Notice> : null}

      <SectionTitle>Email</SectionTitle>
      <Text style={styles.text}>{email}</Text>
      <Notice tone={confirmed ? 'info' : 'warning'}>{confirmed ? 'Your email address is confirmed.' : 'Your email address is not confirmed yet.'}</Notice>
      {!confirmed ? (
        <Button title="Send the confirmation email again" variant="secondary" loading={busy === 'resend'} onPress={() => run('resend', () => resendConfirmation(email), 'We sent a new confirmation email. Check your inbox and spam folder.')} />
      ) : null}

      <SectionTitle>Change password</SectionTitle>
      <Field label="New password" value={next} onChangeText={setNext} secureTextEntry autoCapitalize="none" autoComplete="new-password" />
      <Field label="Type it again" value={again} onChangeText={setAgain} secureTextEntry autoCapitalize="none" autoComplete="new-password" />
      <Button
        title="Change password"
        loading={busy === 'password'}
        onPress={() => {
          const problem = passwordProblem(next, again);
          if (problem) { setError(problem); setDone(''); return; }
          void run('password', async () => { await changePassword(next); setNext(''); setAgain(''); }, 'Your password was changed.');
        }}
      />
      <Button title="Email me a reset link instead" variant="secondary" loading={busy === 'reset'} onPress={() => run('reset', () => sendResetEmail(email), 'We sent a reset link to your email.')} />

      <SectionTitle>Devices</SectionTitle>
      <Text style={styles.text}>If you signed in on a phone you no longer use, you can sign it out. This phone stays signed in.</Text>
      <Button title="Sign out of my other devices" variant="secondary" loading={busy === 'others'} onPress={() => run('others', signOutOtherDevices, 'Other devices were signed out.')} />
      <Text style={styles.small}>A list of each device is not available yet. Phone number verification needs an SMS service and is not set up.</Text>

      <SectionTitle>Delete account</SectionTitle>
      <DangerConfirm copy={ACCOUNT_DELETE} busy={deleting} error={deleteError} onConfirm={deleteAccount} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  text: { fontSize: 15, color: colors.text, lineHeight: 22 },
  small: { fontSize: 12, color: colors.muted, lineHeight: 18 },
});
