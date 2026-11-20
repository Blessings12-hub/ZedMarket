import { useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../src/auth/AuthProvider';
import { Button, Field, Notice, SectionTitle } from '../src/components/ui';
import { validateAppeal } from '../src/domain/trust';
import { APPEAL_STATUS_LABELS, fetchMyAppeals, submitAppeal, type Appeal, type AppealTarget } from '../src/features/trust/api';
import { friendlyError } from '../src/lib/errors';
import { colors, radius, spacing } from '../src/theme';

export default function AppealScreen() {
  const { targetType, targetId } = useLocalSearchParams<{ targetType: AppealTarget; targetId: string }>();
  const { userId } = useAuth();
  const [message, setMessage] = useState('');
  const [past, setPast] = useState<Appeal[]>([]);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!userId || !targetId) return;
    try {
      setPast(await fetchMyAppeals(userId, targetId));
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [userId, targetId]);

  useEffect(() => {
    load();
  }, [load]);

  const waiting = past.some((a) => a.status === 'open');

  async function submit() {
    const problem = validateAppeal(message);
    if (problem || !targetType || !targetId) {
      setError(problem ?? 'Something is missing.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      await submitAppeal(targetType, targetId, message);
      setMessage('');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}

      {past.length > 0 ? <SectionTitle>Your appeals</SectionTitle> : null}
      {past.map((a) => (
        <View key={a.id} style={styles.card}>
          <Text style={styles.status}>{APPEAL_STATUS_LABELS[a.status]}</Text>
          <Text style={styles.body}>{a.message}</Text>
          {a.reviewerNote ? <Text style={styles.note}>Our reply: {a.reviewerNote}</Text> : null}
        </View>
      ))}

      {!waiting ? (
        <>
          <SectionTitle>Ask us to look again</SectionTitle>
          <Text style={styles.text}>If you think we got it wrong, explain why. A different person will read it. Nothing is decided by a computer alone.</Text>
          <Field
            label="Your message"
            value={message}
            onChangeText={setMessage}
            multiline
            maxLength={1500}
            style={{ minHeight: 120, textAlignVertical: 'top' }}
          />
          <Button title="Send appeal" onPress={submit} loading={busy} />
        </>
      ) : (
        <Text style={styles.text}>You already have an appeal waiting. We will reply here.</Text>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  status: { fontSize: 13, fontWeight: '600', color: colors.primary },
  body: { fontSize: 15, lineHeight: 22, color: colors.text },
  note: { fontSize: 14, color: colors.muted },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
});
