import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice } from '../../src/components/ui';
import { formatKwacha } from '../../src/domain/money';
import { completeRefund, decideRefund, fetchFinanceRefunds, type FinanceRefund } from '../../src/features/payments/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

const FILTERS = [
  { key: 'requested', label: 'To approve' }, { key: 'approved', label: 'To send' },
  { key: 'processed', label: 'Done' }, { key: 'rejected', label: 'Rejected' }, { key: 'failed', label: 'Failed' },
];

export default function RefundsScreen() {
  const { userId } = useAuth();
  const [status, setStatus] = useState('requested');
  const [items, setItems] = useState<FinanceRefund[]>([]);
  const [note, setNote] = useState('');
  const [ref, setRef] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try { setItems(await fetchFinanceRefunds(status)); setError(''); } catch (e) { setError(friendlyError(e)); }
  }, [status]);
  useFocusEffect(useCallback(() => { void load(); }, [load]));

  async function run(fn: () => Promise<void>) {
    setBusy(true);
    try { await fn(); setNote(''); setRef(''); await load(); } catch (e) { setError(friendlyError(e)); } finally { setBusy(false); }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: spacing.sm }}>
        {FILTERS.map((f) => <Chip key={f.key} label={f.label} selected={status === f.key} onPress={() => setStatus(f.key)} />)}
      </ScrollView>
      {status === 'requested' || status === 'approved' ? (
        <>
          <Field label={status === 'requested' ? 'Note (needed to reject)' : 'Note'} value={note} onChangeText={setNote} />
          {status === 'approved' ? <Field label="Reference of the money sent back" value={ref} onChangeText={setRef} autoCapitalize="characters" /> : null}
        </>
      ) : null}
      {items.length === 0 ? <Text style={styles.meta}>Nothing here.</Text> : null}
      {items.map((r) => (
        <View key={r.id} style={styles.card}>
          <Text style={styles.title}>{formatKwacha(r.amount)} · {r.paymentRef}</Text>
          <Text style={styles.meta}>{r.reason}</Text>
          {status === 'requested' ? (
            r.requestedBy === userId ? (
              <Text style={styles.meta}>You asked for this one. Someone else has to decide it.</Text>
            ) : (
              <>
                <Button title="Approve" loading={busy} onPress={() => run(() => decideRefund(r.id, true, note))} />
                <Button title="Reject" variant="secondary" loading={busy} onPress={() => run(() => decideRefund(r.id, false, note))} />
              </>
            )
          ) : null}
          {status === 'approved' ? (
            <>
              <Button title="Money sent back" loading={busy} onPress={() => run(() => completeRefund(r.id, true, ref, note))} />
              <Button title="It did not go through" variant="secondary" loading={busy} onPress={() => run(() => completeRefund(r.id, false, '', note))} />
            </>
          ) : null}
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: spacing.sm, borderWidth: 1, borderColor: colors.border },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
});
