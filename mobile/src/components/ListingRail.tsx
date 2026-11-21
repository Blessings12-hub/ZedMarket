import { FlatList, StyleSheet, Text, View } from 'react-native';

import type { ListingSummary } from '../features/listings/types';
import { colors, spacing } from '../theme';
import { ListingCard } from './ListingCard';

const CARD_WIDTH = 160;

// A sideways row of listings under a heading. Renders nothing when there is nothing to show,
// so an empty "Trending" row never appears on a quiet day.
export function ListingRail({
  title,
  note,
  items,
  action,
}: {
  title: string;
  note?: string;
  items: ListingSummary[];
  action?: React.ReactNode;
}) {
  if (items.length === 0) return null;
  return (
    <View style={styles.wrap}>
      {title ? (
        <View style={styles.head}>
          <View style={{ flex: 1 }}>
            <Text style={styles.title}>{title}</Text>
            {note ? <Text style={styles.note}>{note}</Text> : null}
          </View>
          {action}
        </View>
      ) : null}
      <FlatList
        horizontal
        data={items}
        keyExtractor={(i) => i.id}
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={{ paddingHorizontal: spacing.lg, gap: spacing.md }}
        renderItem={({ item }) => <ListingCard listing={item} width={CARD_WIDTH} />}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { gap: spacing.sm, marginBottom: spacing.lg },
  head: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: spacing.lg },
  title: { fontSize: 18, fontWeight: '700', color: colors.text },
  note: { fontSize: 12, color: colors.muted },
});
