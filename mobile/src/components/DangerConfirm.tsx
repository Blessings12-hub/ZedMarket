import { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import type { CloseCopy } from '../domain/closeAccount';
import { colors, radius, spacing } from '../theme';
import { Button, Notice } from './ui';

// A two-step delete. The first press only opens the warning; nothing happens until the second, clearly labelled press.
// It is built from normal views, not Alert, so it works the same on a phone and on the web.
export function DangerConfirm({ copy, busy, error, onConfirm }: { copy: CloseCopy; busy: boolean; error?: string; onConfirm: () => void }) {
  const [open, setOpen] = useState(false);

  if (!open) {
    return <Button title={copy.button} variant="danger" onPress={() => setOpen(true)} />;
  }
  return (
    <View style={styles.box}>
      <Text style={styles.title}>{copy.heading}</Text>
      <Text style={styles.text}>{copy.intro}</Text>
      {copy.points.map((p) => (
        <Text key={p} style={styles.text}>{'•  '}{p}</Text>
      ))}
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Button title={copy.confirm} variant="danger" loading={busy} disabled={busy} onPress={onConfirm} />
      <Button title={copy.keep} variant="secondary" disabled={busy} onPress={() => setOpen(false)} />
    </View>
  );
}

const styles = StyleSheet.create({
  box: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.danger, padding: spacing.md, gap: spacing.sm },
  title: { fontSize: 16, fontWeight: '700', color: colors.danger },
  text: { fontSize: 14, color: colors.text, lineHeight: 20 },
});
