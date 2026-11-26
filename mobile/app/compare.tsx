import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useMemo, useState } from 'react';
import { ActivityIndicator, Image, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Notice } from '../src/components/ui';
import { conditionLabel } from '../src/domain/listing';
import { formatKwacha } from '../src/domain/money';
import { fetchComparison } from '../src/features/comparison/api';
import { canCompare, cheapestId, type Comparison } from '../src/features/comparison/domain';
import { clear, remove, useCompare } from '../src/features/comparison/store';
import { friendlyError } from '../src/lib/errors';
import { singleFlight } from '../src/lib/singleFlight';
import { listingImageUrl } from '../src/lib/supabase';
import { colors, radius, spacing } from '../src/theme';

export default function Compare() {
  const router = useRouter();
  const ids = useCompare();
  const [data, setData] = useState<Comparison | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const load = useMemo(() => singleFlight(async (list: string[]) => {
    if (!canCompare(list)) { setData(null); setError(''); return; }
    setLoading(true);
    try { setData(await fetchComparison(list)); setError(''); } catch (e) { setError(friendlyError(e)); } finally { setLoading(false); }
  }), []);
  useFocusEffect(useCallback(() => { void load(ids); }, [load, ids]));

  const best = data ? cheapestId(data.items) : null;
  const rows: { label: string; get: (i: Comparison['items'][number]) => string }[] = [
    { label: 'Price', get: (i) => formatKwacha(i.price) },
    { label: 'Condition', get: (i) => conditionLabel(i.condition as any) },
    { label: 'Warranty', get: (i) => i.warranty ?? 'Not stated' },
    { label: 'Returns', get: (i) => i.returnPolicy ?? 'Not stated' },
    { label: 'Category', get: (i) => i.category },
    { label: 'Where', get: (i) => [i.area, i.town].filter(Boolean).join(', ') || 'Zambia' },
    { label: 'Seller', get: (i) => `${i.sellerName}${i.sellerLevel === 'identity_verified' ? ' (identity verified)' : ''}` },
    { label: 'Rating', get: (i) => (i.rating == null ? 'No reviews yet' : `${i.rating} from ${i.reviews} review(s)`) },
    { label: 'Completed sales', get: (i) => String(i.completedOrders) },
  ];

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {error ? <Button title="Try again" variant="secondary" onPress={() => void load(ids)} /> : null}
      {!canCompare(ids) ? <Notice>Pick 2 to 4 items with “Compare” on a listing. You have {ids.length}.</Notice> : null}
      {loading ? <ActivityIndicator color={colors.primary} /> : null}
      {data && data.missing.length > 0 ? (
        <Notice tone="warning">{data.missing.length} item(s) are no longer available and were left out.</Notice>
      ) : null}
      {data && !data.sameCategory ? <Notice>These items are in different categories, so some rows may not be comparable.</Notice> : null}
      {data && data.items.length >= 2 ? (
        <ScrollView horizontal>
          <View style={styles.table}>
            <View style={styles.row}>
              {data.items.map((i) => (
                <View key={i.id} style={styles.col}>
                  {i.image ? <Image source={{ uri: listingImageUrl(i.image) }} style={styles.photo} /> : <View style={[styles.photo, styles.noPhoto]} />}
                  <Text style={styles.title} numberOfLines={2}>{i.title}</Text>
                  {i.id === best ? <Text style={styles.best}>Lowest price</Text> : null}
                  <Button title="Open" variant="secondary" onPress={() => router.push(`/listing/${i.id}`)} />
                  <Button title="Remove" variant="secondary" onPress={() => remove(i.id)} />
                </View>
              ))}
            </View>
            {rows.map((r) => (
              <View key={r.label}>
                <Text style={styles.label}>{r.label}</Text>
                <View style={styles.row}>{data.items.map((i) => <Text key={i.id} style={[styles.col, styles.cell]}>{r.get(i)}</Text>)}</View>
              </View>
            ))}
          </View>
        </ScrollView>
      ) : null}
      {ids.length > 0 ? <Button title="Clear the list" variant="secondary" onPress={clear} /> : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl * 2 },
  table: { gap: spacing.sm },
  row: { flexDirection: 'row', gap: spacing.sm },
  col: { width: 160, gap: spacing.sm },
  cell: { fontSize: 14, color: colors.text, backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.sm },
  label: { fontSize: 12, fontWeight: '700', color: colors.muted, marginTop: spacing.sm, textTransform: 'uppercase' },
  photo: { width: 160, height: 120, borderRadius: radius.md },
  noPhoto: { backgroundColor: colors.border },
  title: { fontSize: 14, fontWeight: '700', color: colors.text },
  best: { fontSize: 12, fontWeight: '700', color: colors.primary },
});
