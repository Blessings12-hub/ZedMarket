import { useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text } from 'react-native';
import { useFocusEffect } from 'expo-router';

import { Notice } from '../../../src/components/ui';
import { choiceLabel, formatWhen, statusLabel } from '../../../src/domain/voting';
import { fetchMyVotes, type MyVote } from '../../../src/features/voting/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

// Only the person's own votes. Nobody else's choices are ever returned to the app.
export default function VoteHistory() {
  const router = useRouter();
  const [items, setItems] = useState<MyVote[] | null>(null);
  const [error, setError] = useState('');

  useFocusEffect(
    useCallback(() => {
      fetchMyVotes()
        .then((v) => {
          setItems(v);
          setError('');
        })
        .catch((e) => {
          setItems([]);
          setError(friendlyError(e));
        });
    }, []),
  );

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.text}>Only you can see how you voted.</Text>
      {items === null ? <ActivityIndicator color={colors.primary} /> : null}
      {items && items.length === 0 && !error ? <Text style={styles.text}>You have not voted on anything yet.</Text> : null}
      {items?.map((v) => (
        <Pressable key={v.proposalId} accessibilityRole="button" onPress={() => router.push(`/admin/votes/${v.proposalId}`)} style={styles.card}>
          <Text style={styles.ref}>{v.reference} · {statusLabel(v.status)}</Text>
          <Text style={styles.cardTitle}>{v.confidential ? 'Confidential: ' : ''}{v.title}</Text>
          <Text style={styles.meta}>You voted {choiceLabel(v.myChoice).toLowerCase()} on {formatWhen(v.castAt)}</Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  card: { padding: spacing.md, gap: spacing.xs, borderRadius: radius.md, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  ref: { fontSize: 13, fontWeight: '600', color: colors.muted },
  cardTitle: { fontSize: 16, fontWeight: '700', color: colors.text },
  meta: { fontSize: 14, color: colors.muted },
});
