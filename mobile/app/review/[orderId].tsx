import { useLocalSearchParams, useRouter } from 'expo-router';
import { useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { RATINGS, ratingLabel, validateReview } from '../../src/domain/trust';
import { submitReview } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, spacing } from '../../src/theme';

export default function ReviewScreen() {
  const { orderId } = useLocalSearchParams<{ orderId: string }>();
  const router = useRouter();
  const [rating, setRating] = useState<number | null>(null);
  const [comment, setComment] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);

  async function submit() {
    const problem = validateReview(rating, comment);
    if (problem || !orderId || rating === null) {
      setError(problem ?? 'Something is missing.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      await submitReview(orderId, rating, comment);
      setSent(true);
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (sent) {
    return (
      <View style={styles.done}>
        <Text style={styles.title}>Thank you</Text>
        <Text style={styles.text}>Your review helps other people decide who to trust.</Text>
        <Button title="Done" onPress={() => router.back()} />
      </View>
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      <SectionTitle>How did it go?</SectionTitle>
      <View style={styles.row}>
        {RATINGS.map((n) => (
          <Chip key={n} label={`${n}`} selected={rating === n} onPress={() => setRating(n)} />
        ))}
      </View>
      {rating ? <Text style={styles.text}>{ratingLabel(rating)}</Text> : <Text style={styles.text}>1 is poor, 5 is excellent.</Text>}
      <Field
        label="Say a little more (optional)"
        value={comment}
        onChangeText={setComment}
        multiline
        maxLength={1000}
        style={{ minHeight: 100, textAlignVertical: 'top' }}
      />
      <Text style={styles.text}>Be honest and fair. Reviews that break our rules can be hidden.</Text>
      <Button title="Post review" onPress={submit} loading={busy} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  row: { flexDirection: 'row', gap: spacing.sm },
  done: { flex: 1, padding: spacing.xl, gap: spacing.lg, justifyContent: 'center', backgroundColor: colors.background },
  title: { fontSize: 24, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
});
