import { Link } from 'expo-router';
import { useState } from 'react';
import { KeyboardAvoidingView, Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Field, Notice } from '../../src/components/ui';
import { TERMS_VERSION } from '../../src/domain/legal';
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
  const [agreed, setAgreed] = useState(false);

  async function signUp() {
    setError('');
    if (name.trim().length < 2) return setError('Enter the name other people will see.');
    if (!/^\S+@\S+\.\S+$/.test(email.trim())) return setError('Enter a valid email address.');
    if (password.length < 8) return setError('Use a password with at least 8 characters.');
    if (!agreed) return setError('Please agree to the Terms of Use and Privacy Notice to create an account.');

    setBusy(true);
    const { data, error: failure } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: { data: { display_name: name.trim(), accepted_terms_version: TERMS_VERSION } },
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
              <Pressable accessibilityRole="checkbox" accessibilityState={{ checked: agreed }} onPress={() => setAgreed(!agreed)} style={styles.agree}>
                <View style={[styles.box, agreed ? styles.boxOn : null]}>{agreed ? <Text style={styles.tick}>✓</Text> : null}</View>
                <Text style={styles.agreeText}>
                  I agree to the <Link href="/legal/terms" style={styles.link}>Terms of Use</Link> and the <Link href="/legal/privacy" style={styles.link}>Privacy Notice</Link>.
                </Text>
              </Pressable>
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
  agree: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  box: { width: 24, height: 24, borderRadius: 6, borderWidth: 2, borderColor: colors.border, alignItems: 'center', justifyContent: 'center' },
  boxOn: { backgroundColor: colors.primary, borderColor: colors.primary },
  tick: { color: '#fff', fontWeight: '800' },
  agreeText: { flex: 1, color: colors.text, fontSize: 14, lineHeight: 20 },
});
