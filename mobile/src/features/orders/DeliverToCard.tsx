import { StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing } from '../../theme';
import type { DeliverTo } from './deliverTo';

export function DeliverToCard({ info }: { info: DeliverTo }) {
  return (
    <View style={[styles.card, info.missing && styles.missing]} accessibilityLabel={`${info.title}: ${info.address}`}>
      <Text style={styles.title} accessibilityRole="header">{info.title}</Text>
      <Text style={styles.address}>{info.address}</Text>
      <Text style={styles.meta}>Buyer: {info.buyerName}</Text>
      {info.note ? <Text style={styles.meta}>Buyer's note: {info.note}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.primarySoft, borderRadius: radius.md, borderWidth: 1, borderColor: colors.primary, padding: spacing.lg, gap: spacing.xs },
  missing: { backgroundColor: colors.warningSoft, borderColor: colors.warning },
  title: { fontSize: 13, fontWeight: '700', letterSpacing: 0.5, textTransform: 'uppercase', color: colors.primaryDark },
  address: { fontSize: 17, fontWeight: '700', color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
});
