import { Ionicons } from '@expo/vector-icons';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing } from '../../theme';
import type { StaffBoard } from './dashboard';

// "Needs attention": one card per queue with something waiting, urgent ones first. Tapping opens that queue.
export function StaffBoardView({ board, onOpen }: { board: StaffBoard; onOpen: (href: string) => void }) {
  if (!board.hasQueues) return null;
  return (
    <View style={{ gap: spacing.sm }}>
      <Text style={styles.title} accessibilityRole="header">Needs attention{board.total > 0 ? ` (${board.total})` : ''}</Text>
      {board.allClear ? (
        <View style={styles.calm}>
          <Ionicons name="checkmark-circle-outline" size={20} color={colors.primary} accessibilityElementsHidden />
          <Text style={styles.calmText}>All clear. Nothing is waiting for you.</Text>
        </View>
      ) : (
        board.cards.map((c) => (
          <Pressable
            key={c.key}
            accessibilityRole="button"
            accessibilityLabel={`${c.title}, ${c.count}${c.waiting ? `, ${c.waiting}` : ''}${c.urgent ? ', urgent' : ''}`}
            onPress={() => onOpen(c.href)}
            style={[styles.card, c.urgent && styles.urgent]}
          >
            <Text style={[styles.count, c.urgent && { color: colors.warning }]}>{c.count}</Text>
            <View style={{ flex: 1 }}>
              <Text style={styles.cardTitle}>{c.title}</Text>
              {c.waiting ? <Text style={[styles.muted, c.urgent && { color: colors.warning, fontWeight: '600' }]}>Oldest {c.waiting}</Text> : null}
            </View>
            <Ionicons name="chevron-forward" size={18} color={colors.muted} accessibilityElementsHidden />
          </Pressable>
        ))
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  title: { fontSize: 13, fontWeight: '700', letterSpacing: 0.6, textTransform: 'uppercase', color: colors.muted },
  card: { flexDirection: 'row', alignItems: 'center', gap: spacing.md, minHeight: 64, backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md },
  urgent: { borderColor: colors.warning, backgroundColor: colors.warningSoft },
  count: { minWidth: 36, fontSize: 24, fontWeight: '700', color: colors.primary, textAlign: 'center' },
  cardTitle: { fontSize: 16, fontWeight: '600', color: colors.text },
  muted: { fontSize: 13, color: colors.muted },
  calm: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, backgroundColor: colors.primarySoft, borderRadius: radius.md, padding: spacing.md },
  calmText: { fontSize: 14, fontWeight: '600', color: colors.primaryDark },
});
