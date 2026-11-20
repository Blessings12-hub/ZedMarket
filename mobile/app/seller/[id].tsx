import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import { Notice } from '../../src/components/ui';
import { fetchReviewsAbout, type ReviewItem } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function SellerReviews() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [items, setItems] = useState<ReviewItem[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!id) return;
    fetchReviewsAbout(id)
      .then(setItems)
      .catch((e) => setError(friendlyError(e)))
      .finally(() => setLoading(false));
  }, [id]);

  return (
    <View style={styles.screen}>
      {error ? (
        <View style={{ padding: spacing.lg }}>
          <Notice tone="error">{error}</Notice>
        </View>
      ) : null}
      <FlatList
        data={items}
        keyExtractor={(r) => r.id}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, flexGrow: 1 }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>No reviews yet.</Text>}
        renderItem={({ item }) => (
          <View style={styles.card}>
            <Text style={styles.rating}>{item.rating} out of 5</Text>
            {item.comment ? <Text style={styles.comment}>{item.comment}</Text> : null}
            <Text style={styles.meta}>
              {item.reviewerName} · {new Date(item.createdAt).toLocaleDateString()}
            </Text>
            <Pressable
              accessibilityRole="button"
              onPress={() => router.push({ pathname: '/report', params: { targetType: 'review', targetId: item.id } })}
            >
              <Text style={styles.report}>Report this review</Text>
            </Pressable>
          </View>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  rating: { fontSize: 16, fontWeight: '700', color: colors.text },
  comment: { fontSize: 15, lineHeight: 22, color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
  report: { fontSize: 13, color: colors.muted, textDecorationLine: 'underline', marginTop: spacing.xs },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
