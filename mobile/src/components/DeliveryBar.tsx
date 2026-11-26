import { Ionicons } from '@expo/vector-icons';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing } from '../theme';

// The strip at the very top of Home: where orders will be delivered, and a tap to change it.
export function DeliveryBar({ line, onPress }: { line: string | null; onPress: () => void }) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={line ? `Deliver to ${line}. Tap to change` : 'Add your delivery location'}
      onPress={onPress}
      style={styles.bar}
    >
      <Ionicons name="location-outline" size={20} color={colors.primary} accessibilityElementsHidden />
      <View style={{ flex: 1 }}>
        <Text style={styles.small}>{line ? 'Deliver to' : 'Delivery location'}</Text>
        <Text style={styles.line} numberOfLines={1}>{line ?? 'Add where we should deliver'}</Text>
      </View>
      <Ionicons name="chevron-down" size={18} color={colors.muted} accessibilityElementsHidden />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  bar: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, minHeight: 52, marginHorizontal: spacing.lg, marginTop: spacing.sm, paddingHorizontal: spacing.md, borderRadius: radius.md, backgroundColor: colors.primarySoft },
  small: { fontSize: 11, color: colors.muted },
  line: { fontSize: 15, fontWeight: '700', color: colors.primaryDark },
});
