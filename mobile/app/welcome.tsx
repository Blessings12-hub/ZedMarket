import { useRouter } from 'expo-router';
import { useState } from 'react';
import { KeyboardAvoidingView, Platform, ScrollView, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Button, Field, Notice } from '../src/components/ui';
import { cleanInviteCode, isInviteCode } from '../src/domain/invite';
import { WELCOME_SLIDES } from '../src/domain/welcome';
import { redeemInviteCode } from '../src/features/launch/api';
import { friendlyError } from '../src/lib/errors';
import { useAuth } from '../src/auth/AuthProvider';
import { markWelcomeSeen } from '../src/lib/welcomeSeen';
import { colors, radius, spacing } from '../src/theme';

// Shown once, after the first sign-in on a phone. Skipping is always possible.
export default function Welcome() {
  const router = useRouter();
  const { userId } = useAuth();
  const [step, setStep] = useState(0);
  const [code, setCode] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const last = step === WELCOME_SLIDES.length - 1;
  const slide = WELCOME_SLIDES[step] ?? WELCOME_SLIDES[0]!;

  async function finish() {
    setError('');
    if (code.trim() !== '') {
      if (!isInviteCode(code)) return setError('That invite code does not look right. It has 8 letters and numbers.');
      setBusy(true);
      try {
        await redeemInviteCode(cleanInviteCode(code));
      } catch (e) {
        setBusy(false);
        return setError(friendlyError(e));
      }
      setBusy(false);
    }
    if (userId) markWelcomeSeen(userId);
    router.replace('/(tabs)');
  }

  function skip() {
    if (userId) markWelcomeSeen(userId);
    router.replace('/(tabs)');
  }

  return (
    <SafeAreaView style={styles.screen}>
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={{ flex: 1 }}>
        <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
          <Text style={styles.brand}>Welcome to ZedMarket</Text>
          <View style={styles.card}>
            <Text style={styles.title}>{slide.title}</Text>
            <Text style={styles.body}>{slide.body}</Text>
          </View>
          <View style={styles.dots}>
            {WELCOME_SLIDES.map((s, i) => (
              <View key={s.title} style={[styles.dot, i === step ? styles.dotOn : null]} />
            ))}
          </View>
          {last ? (
            <>
              {error ? <Notice tone="error">{error}</Notice> : null}
              <Field label="Invite code from a friend (optional)" value={code} onChangeText={setCode} autoCapitalize="characters" autoCorrect={false} maxLength={12} />
              <Button title="Start browsing" onPress={finish} loading={busy} />
            </>
          ) : (
            <Button title="Next" onPress={() => setStep(step + 1)} />
          )}
          <Button title="Skip" variant="secondary" onPress={skip} disabled={busy} />
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.xl, gap: spacing.lg, flexGrow: 1, justifyContent: 'center' },
  brand: { fontSize: 14, fontWeight: '700', color: colors.primary, textTransform: 'uppercase', letterSpacing: 1 },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.xl, gap: spacing.md },
  title: { fontSize: 24, fontWeight: '700', color: colors.text },
  body: { fontSize: 16, color: colors.text, lineHeight: 24 },
  dots: { flexDirection: 'row', gap: spacing.sm, justifyContent: 'center' },
  dot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.border },
  dotOn: { backgroundColor: colors.primary },
});
