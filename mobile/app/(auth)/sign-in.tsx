import { Link } from 'expo-router';
import { useState } from 'react';
import { KeyboardAvoidingView, Platform, ScrollView, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Field, Notice } from '../../src/components/ui';
import { friendlyError } from '../../src/lib/errors';
import { supabase } from '../../src/lib/supabase';
import { colors, spacing } from '../../src/theme';

export default function SignIn() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [info, setInfo] = useState('');

  async function signIn() {
    setError('');
    setInfo('');
    if (!email.trim() || !password) {
      setError('Enter your email and password.');
      return;
    }
    setBusy(true);
    const { error: failure } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    setBusy(false);
    if (failure) setError(failure.message === 'Invalid login credentials' ? 'That email and password do not match.' : friendlyError(failure));
  }

  async function forgotPassword() {
    setError('');
    setInfo('');
    if (!email.trim()) {
      setError('Enter your email above first.');
      return;
    }
    const { error: failure } = await supabase.auth.resetPasswordForEmail(email.trim());
    if (failure) setError(friendlyError(failure));
    else setInfo('If an account exists for that email, a reset link is on its way.');
  }

  return (
    <SafeAreaView style={styles.screen}>
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={{ flex: 1 }}>
        <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
          <View>
            <Text style={styles.brand}>ZedMarket</Text>
            <Text style={styles.tagline}>Buy. Sell. Deliver.</Text>
          </View>

          {error ? <Notice tone="error">{error}</Notice> : null}
          {info ? <Notice>{info}</Notice> : null}

          <Field
            label="Email"
            value={email}
            onChangeText={setEmail}
            autoCapitalize="none"
            autoComplete="email"
            keyboardType="email-address"
          />
          <Field label="Password" value={password} onChangeText={setPassword} secureTextEntry autoComplete="password" />

          <Button title="Sign in" onPress={signIn} loading={busy} />
          <Button title="Forgot password" variant="secondary" onPress={forgotPassword} />

          <Text style={styles.footer}>
            New here? <Link href="/sign-up" style={styles.link}>Create an account</Link>
          </Text>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.xl, gap: spacing.lg, flexGrow: 1, justifyContent: 'center' },
  brand: { fontSize: 34, fontWeight: '800', color: colors.primary },
  tagline: { fontSize: 16, color: colors.muted, marginTop: spacing.xs },
  footer: { textAlign: 'center', color: colors.muted, marginTop: spacing.md },
  link: { color: colors.primary, fontWeight: '600' },
});
