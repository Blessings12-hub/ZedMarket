import { Link } from 'expo-router';
import { useState } from 'react';
import { KeyboardAvoidingView, Platform, ScrollView, StyleSheet, Text } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Field, Notice } from '../../src/components/ui';
import { friendlyError } from '../../src/lib/errors';
import { supabase } from '../../src/lib/supabase';
import { colors, spacing } from '../../src/theme';

export default function SignUp() {
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [sent, setSent] = useState(false);

  async function signUp() {
    setError('');
    if (name.trim().length < 2) return setError('Enter the name other people will see.');
    if (!/^\S+@\S+\.\S+$/.test(email.trim())) return setError('Enter a valid email address.');
    if (password.length < 8) return setError('Use a password with at least 8 characters.');

    setBusy(true);
    const { data, error: failure } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: { data: { display_name: name.trim() } },
    });
    setBusy(false);

    if (failure) return setError(friendlyError(failure));
    // With email confirmation switched on there is no session yet.
    if (!data.session) setSent(true);
  }

  return (
    <SafeAreaView style={styles.screen}>
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={{ flex: 1 }}>
        <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
          <Text style={styles.title}>Create your account</Text>

          {sent ? (
            <>
              <Notice>We sent a confirmation link to {email.trim()}. Open it, then come back and sign in.</Notice>
              <Link href="/sign-in" style={styles.link}>Go to sign in</Link>
            </>
          ) : (
            <>
              {error ? <Notice tone="error">{error}</Notice> : null}
              <Field label="Your name" value={name} onChangeText={setName} autoComplete="name" maxLength={60} />
              <Field
                label="Email"
                value={email}
                onChangeText={setEmail}
                autoCapitalize="none"
                autoComplete="email"
                keyboardType="email-address"
              />
              <Field
                label="Password"
                value={password}
                onChangeText={setPassword}
                secureTextEntry
                autoComplete="new-password"
              />
              <Button title="Create account" onPress={signUp} loading={busy} />
              <Text style={styles.footer}>
                Already have an account? <Link href="/sign-in" style={styles.link}>Sign in</Link>
              </Text>
            </>
          )}
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.xl, gap: spacing.lg, flexGrow: 1, justifyContent: 'center' },
  title: { fontSize: 26, fontWeight: '700', color: colors.text },
  footer: { textAlign: 'center', color: colors.muted },
  link: { color: colors.primary, fontWeight: '600' },
});
