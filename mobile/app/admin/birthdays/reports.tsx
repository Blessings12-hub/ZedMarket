import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice } from '../../../src/components/ui';
import { reasonProblem } from '../../../src/domain/admin';
import { formatWhen } from '../../../src/domain/voting';
import { decideWishReport, fetchWishReports, type WishReport } from '../../../src/features/birthdays/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

// Moderators and technical admins only. The database refuses everyone else, so this screen just shows the refusal.
export default function WishReports() {
  const [items, setItems] = useState<WishReport[] | null>(null);
  const [open, setOpen] = useState<{ id: string; action: 'hide' | 'dismiss' } | null>(null);
  const [note, setNote] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setItems(await fetchWishReports());
      setError('');
    } catch (e) {
      setItems([]);
      setError(friendlyError(e) === 'Not allowed.' ? 'Only moderators and technical admins who have signed in with their two-factor code can see reported wishes.' : friendlyError(e));
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  const problem = note ? reasonProblem(note) : null;

  async function decide() {
    if (!open) return;
    setBusy(true);
    setError('');
    try {
      await decideWishReport(open.id, open.action, note.trim());
      setOpen(null);
      setNote('');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {items === null ? <ActivityIndicator color={colors.primary} /> : null}
      {items && items.length === 0 && !error ? <Text style={styles.text}>No reported wishes.</Text> : null}
      {items?.map((r) => (
        <View key={r.reportId} style={styles.card}>
          <Text style={styles.meta}>{r.birthdayPerson}'s board · {formatWhen(r.createdAt)}</Text>
          <Text style={styles.body}>"{r.body}"</Text>
          <Text style={styles.meta}>Written by {r.senderName} · reported by {r.reporterName}</Text>
          <Text style={styles.meta}>Reason: {r.reason}</Text>
          {open?.id === r.reportId ? (
            <>
              <Field label="Your reason (saved in the audit log)" value={note} onChangeText={setNote} error={problem ?? undefined} maxLength={300} />
              <Button title={open.action === 'hide' ? 'Hide this message' : 'Dismiss the report'} variant={open.action === 'hide' ? 'danger' : 'primary'} loading={busy} disabled={!note || !!problem} onPress={decide} />
              <Button title="Cancel" variant="secondary" disabled={busy} onPress={() => setOpen(null)} />
            </>
          ) : (
            <>
              <Button title="Hide message" variant="danger" onPress={() => { setOpen({ id: r.reportId, action: 'hide' }); setNote(''); }} />
              <Button title="Dismiss report" variant="secondary" onPress={() => { setOpen({ id: r.reportId, action: 'dismiss' }); setNote(''); }} />
            </>
          )}
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  card: { gap: spacing.sm, padding: spacing.md, borderRadius: radius.md, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  body: { fontSize: 16, lineHeight: 22, color: colors.text },
  meta: { fontSize: 14, color: colors.muted },
});
