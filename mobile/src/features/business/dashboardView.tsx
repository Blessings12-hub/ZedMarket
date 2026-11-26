import { Ionicons } from '@expo/vector-icons';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing } from '../../theme';
import type { AttentionTile, SalesSummary, SetupStep } from './dashboard';

// Tiles for what needs the shop today. A quiet shop sees one calm line instead.
export function AttentionTiles({ tiles, onOpen }: { tiles: AttentionTile[]; onOpen: (t: AttentionTile) => void }) {
  if (tiles.length === 0) {
    return (
      <View style={styles.calm}>
        <Ionicons name="checkmark-circle-outline" size={20} color={colors.primary} accessibilityElementsHidden />
        <Text style={styles.calmText}>Nothing needs you right now.</Text>
      </View>
    );
  }
  return (
    <View style={styles.row}>
      {tiles.map((t) => (
        <Pressable key={t.key} accessibilityRole="button" accessibilityLabel={`${t.label}, ${t.count}`} onPress={() => onOpen(t)} style={[styles.tile, t.urgent && styles.tileUrgent]}>
          <Text style={[styles.count, t.urgent && { color: colors.warning }]}>{t.count}</Text>
          <Text style={styles.label} numberOfLines={2}>{t.label}</Text>
        </Pressable>
      ))}
    </View>
  );
}

export function SetupChecklist({ steps, done, total, onOpen }: { steps: SetupStep[]; done: number; total: number; onOpen: (s: SetupStep) => void }) {
  return (
    <View style={styles.card}>
      <Text style={styles.heading} accessibilityRole="header">Set up your shop ({done} of {total})</Text>
      <View style={styles.bar} accessibilityElementsHidden><View style={[styles.barFill, { width: `${total === 0 ? 0 : Math.round((done / total) * 100)}%` }]} /></View>
      {steps.map((s) => (
        <Pressable key={s.key} accessibilityRole="button" accessibilityState={{ checked: s.done }} accessibilityLabel={`${s.title}${s.done ? ', done' : ''}`} onPress={() => onOpen(s)} style={styles.step}>
          <Ionicons name={s.done ? 'checkmark-circle' : 'ellipse-outline'} size={22} color={s.done ? colors.primary : colors.muted} accessibilityElementsHidden />
          <View style={{ flex: 1 }}>
            <Text style={[styles.stepTitle, s.done && { color: colors.muted, textDecorationLine: 'line-through' }]}>{s.title}</Text>
            {!s.done ? <Text style={styles.muted}>{s.hint}</Text> : null}
          </View>
          {!s.done ? <Ionicons name="chevron-forward" size={18} color={colors.muted} accessibilityElementsHidden /> : null}
        </Pressable>
      ))}
    </View>
  );
}

export function SalesCard({ sales, onOpen }: { sales: SalesSummary; onOpen: () => void }) {
  return (
    <Pressable accessibilityRole="button" accessibilityLabel={`Sales, ${sales.periodLabel}. Open analytics`} onPress={onOpen} style={styles.card}>
      <Text style={styles.heading} accessibilityRole="header">Sales, {sales.periodLabel}</Text>
      {sales.empty ? (
        <Text style={styles.muted}>No orders yet in this period. They will show here as they come in.</Text>
      ) : (
        <>
          <View style={styles.row}>
            <View style={{ flex: 1 }}><Text style={styles.count}>{sales.revenue}</Text><Text style={styles.muted}>Completed sales</Text></View>
            <View style={{ flex: 1 }}><Text style={styles.count}>{sales.completedOrders}</Text><Text style={styles.muted}>Orders done ({sales.ordersReceived} received)</Text></View>
          </View>
          {sales.top.length > 0 ? (
            <View style={{ gap: 2 }}>
              <Text style={styles.stepTitle}>Best sellers</Text>
              {sales.top.map((t) => <Text key={t.id} style={styles.muted} numberOfLines={1}>{t.title}: {t.completed} sold</Text>)}
            </View>
          ) : null}
        </>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  tile: { flexBasis: '30%', flexGrow: 1, minHeight: 76, backgroundColor: colors.primarySoft, borderRadius: radius.md, padding: spacing.md, justifyContent: 'center', gap: 2 },
  tileUrgent: { backgroundColor: colors.warningSoft },
  count: { fontSize: 22, fontWeight: '700', color: colors.text },
  label: { fontSize: 13, fontWeight: '600', color: colors.primaryDark },
  calm: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, backgroundColor: colors.primarySoft, borderRadius: radius.md, padding: spacing.md },
  calmText: { fontSize: 14, fontWeight: '600', color: colors.primaryDark },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  heading: { fontSize: 16, fontWeight: '700', color: colors.text },
  muted: { fontSize: 13, lineHeight: 18, color: colors.muted },
  bar: { height: 6, borderRadius: 3, backgroundColor: colors.border, overflow: 'hidden' },
  barFill: { height: 6, backgroundColor: colors.primary },
  step: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, minHeight: 48 },
  stepTitle: { fontSize: 15, fontWeight: '600', color: colors.text },
});
