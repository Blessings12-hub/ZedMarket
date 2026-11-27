import type { ReactNode } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Notice } from '../../components/ui';
import { colors, radius, spacing } from '../../theme';

// Common frame for every Media screen: loading, a clear error with retry, and a permission message.
export function MediaScreen({ loading, error, onRetry, denied, children }: { loading?: boolean; error?: string; onRetry?: () => void; denied?: string; children?: ReactNode }) {
  if (denied) {
    return (
      <View style={styles.center}>
        <Text style={styles.title}>Not available</Text>
        <Text style={styles.muted}>{denied}</Text>
      </View>
    );
  }
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? (
        <>
          <Notice tone="error">{error}</Notice>
          {onRetry ? <Button title="Try again" variant="secondary" onPress={onRetry} /> : null}
        </>
      ) : null}
      {loading && !error ? <ActivityIndicator color={colors.primary} /> : null}
      {children}
    </ScrollView>
  );
}

export function Card({ title, note, meta, onPress, right }: { title: string; note?: string; meta?: string; onPress?: () => void; right?: string }) {
  return (
    <Pressable accessibilityRole={onPress ? 'button' : undefined} disabled={!onPress} onPress={onPress} style={({ pressed }) => [styles.card, pressed && { backgroundColor: colors.primarySoft }]}>
      <View style={{ flex: 1, gap: 2 }}>
        <Text style={styles.cardTitle}>{title}</Text>
        {note ? <Text style={styles.muted}>{note}</Text> : null}
        {meta ? <Text style={styles.meta}>{meta}</Text> : null}
      </View>
      {right ? <Text style={styles.pill}>{right}</Text> : null}
    </Pressable>
  );
}

export const when = (iso: string | null | undefined) =>
  iso ? new Date(iso).toLocaleString('en-GB', { timeZone: 'Africa/Lusaka', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '';

export const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl * 2 },
  center: { flex: 1, padding: spacing.xl, gap: spacing.md, justifyContent: 'center', backgroundColor: colors.background },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  muted: { fontSize: 14, lineHeight: 20, color: colors.muted },
  meta: { fontSize: 12, color: colors.muted },
  card: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md },
  cardTitle: { fontSize: 16, fontWeight: '600', color: colors.text },
  pill: { fontSize: 12, fontWeight: '700', color: colors.primaryDark, backgroundColor: colors.primarySoft, borderRadius: 999, paddingHorizontal: 10, paddingVertical: 3, overflow: 'hidden' },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
});
