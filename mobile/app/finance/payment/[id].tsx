import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice, SectionTitle } from '../../../src/components/ui';
import { formatKwacha } from '../../../src/domain/money';
import { methodLabel, refundProblem, statusLabel } from '../../../src/domain/payments';
import { fetchPaymentDetail, reconcilePayment, requestRefund } from '../../../src/features/payments/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

export default function FinancePaymentScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [d, setD] = useState<any>(null);
  const [ref, setRef] = useState('');
  const [note, setNote] = useState('');
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [error, setError] = useState('');
  const [done, setDone] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      setD(await fetchPaymentDetail(id));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [id]);
  useFocusEffect(useCallback(() => { void load(); }, [load]));

  async function run(fn: () => Promise<void>, message: string) {
    setBusy(true);
    setError('');
    try {
      await fn();
      setDone(message);
      setNote(''); setRef(''); setAmount(''); setReason('');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!d) return <ScrollView style={styles.screen} contentContainerStyle={styles.content}>{error ? <Notice tone="error">{error}</Notice> : <Text style={styles.meta}>Loading…</Text>}</ScrollView>;

  const p = d.payment;
  const committed = (d.refunds as any[]).filter((r) => ['requested', 'approved', 'processed'].includes(r.status)).reduce((s, r) => s + Number(r.amount_zmw), 0);
  const left = Math.round((Number(p.amount_zmw) - committed) * 100) / 100;
  const canReconcile = p.status === 'pending' || p.needs_review;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {done ? <Notice>{done}</Notice> : null}
      <View style={styles.card}>
        <Text style={styles.title}>{p.ref} · {formatKwacha(Number(p.amount_zmw))}</Text>
        <Text style={styles.meta}>{p.order_ref} · {methodLabel(p.method)} · {p.phone_masked}</Text>
        <Text style={styles.status}>{statusLabel(p.status, p.needs_review)}</Text>
        {p.provider_ref ? <Text style={styles.meta}>Provider reference {p.provider_ref} ({p.confirmed_via})</Text> : null}
        {p.failure_reason ? <Text style={styles.meta}>{p.failure_reason}</Text> : null}
        {Number(p.refunded_zmw) > 0 ? <Text style={styles.meta}>Refunded {formatKwacha(Number(p.refunded_zmw))}</Text> : null}
        {p.reconcile_note ? <Text style={styles.meta}>Finance note: {p.reconcile_note}</Text> : null}
      </View>

      {canReconcile ? (
        <>
          <SectionTitle>Reconcile with the provider statement</SectionTitle>
          <Text style={styles.meta}>Only mark a payment paid when you have seen it on the provider statement. Say what you checked.</Text>
          <Field label="Provider reference (needed to mark paid)" value={ref} onChangeText={setRef} autoCapitalize="characters" />
          <Field label="What you checked" value={note} onChangeText={setNote} multiline />
          <Button title="Mark as paid" loading={busy} onPress={() => run(() => reconcilePayment(p.id, 'succeeded', ref, note), 'Marked as paid.')} />
          {p.status !== 'succeeded' ? (
            <Button title="No money received" variant="secondary" loading={busy} onPress={() => run(() => reconcilePayment(p.id, 'failed', '', note), 'Closed as not paid.')} />
          ) : null}
        </>
      ) : null}

      {p.status === 'succeeded' && left > 0 ? (
        <>
          <SectionTitle>Ask for a refund</SectionTitle>
          <Text style={styles.meta}>Up to {formatKwacha(left)} can still be refunded. A different finance person must approve it.</Text>
          <Field label="Amount in kwacha" value={amount} onChangeText={setAmount} keyboardType="decimal-pad" />
          <Field label="Reason" value={reason} onChangeText={setReason} multiline />
          <Button
            title="Request refund"
            loading={busy}
            onPress={() => {
              const problem = refundProblem(Number(amount), left, reason);
              if (problem) { setError(problem); return; }
              void run(() => requestRefund(p.id, Number(amount), reason), 'Refund requested. Someone else needs to approve it.');
            }}
          />
        </>
      ) : null}

      <SectionTitle>History</SectionTitle>
      {(d.events as any[]).map((e, i) => (
        <Text key={i} style={styles.meta}>{String(e.at).slice(0, 16).replace('T', ' ')} · {e.actor} · {e.event}</Text>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: 4, borderWidth: 1, borderColor: colors.border },
  title: { fontSize: 18, fontWeight: '700', color: colors.text },
  status: { fontSize: 15, fontWeight: '700', color: colors.primary },
  meta: { fontSize: 13, color: colors.muted, lineHeight: 19 },
});
