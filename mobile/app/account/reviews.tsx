import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Notice, SectionTitle } from '../../src/components/ui';
import { fetchReviewsIWrote, type WrittenReview } from '../../src/features/account-hub/api';
import { fetchReviewsAbout, type ReviewItem } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

const stars = (n: number) => `${n} out of 5`;

export default function MyReviews() {
  const { userId } = useAuth();
  const [wrote, setWrote] = useState<WrittenReview[] | null>(null);
  const [about, setAbout] = useState<ReviewItem[]>([]);
  const [error, setError] = useState('');

  useFocusEffect(
    useCallback(() => {
      if (!userId) return;
      Promise.all([fetchReviewsIWrote(userId), fetchReviewsAbout(userId)])
        .then(([w, a]) => { setWrote(w); setAbout(a); setError(''); })
        .catch((e) => { setWrote([]); setError(friendlyError(e)); });
    }, [userId]),
  );

  if (!wrote) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <SectionTitle>Reviews you wrote</SectionTitle>
      {wrote.length === 0 ? <Text style={styles.hint}>You have not reviewed anything yet. You can review an order once it is complete.</Text> : null}
      {wrote.map((r) => (
        <View key={r.id} style={styles.card}>
          <Text style={styles.title}>{r.item}</Text>
          <Text style={styles.hint}>For {r.about} · {stars(r.rating)} · {r.createdAt.slice(0, 10)}</Text>
          {r.comment ? <Text style={styles.body}>{r.comment}</Text> : null}
        </View>
      ))}
      <SectionTitle>Reviews about you</SectionTitle>
      {about.length === 0 ? <Text style={styles.hint}>Nobody has reviewed you yet.</Text> : null}
      {about.map((r) => (
        <View key={r.id} style={styles.card}>
          <Text style={styles.title}>{r.reviewerName}</Text>
          <Text style={styles.hint}>{stars(r.rating)} · {r.createdAt.slice(0, 10)}</Text>
          {r.comment ? <Text style={styles.body}>{r.comment}</Text> : null}
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.sm },
  center: { flex: 1, justifyContent: 'center', backgroundColor: colors.background },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 2 },
  title: { fontSize: 15, fontWeight: '600', color: colors.text },
  body: { fontSize: 14, color: colors.text, lineHeight: 20, marginTop: 4 },
  hint: { fontSize: 13, color: colors.muted, lineHeight: 18 },
});
