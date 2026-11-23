import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { Image, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';

import { useAuth } from '../../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../../src/components/ui';
import { RESOLUTION_CODES, staffStatusLabel } from '../../../src/domain/support';
import {
  claimTicket, escalateTicket, evidenceLink, fetchStaffTicket, resolveTicket, setTicketStatus, staffReply,
} from '../../../src/features/support/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

export default function StaffTicketScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { userId } = useAuth();
  const [d, setD] = useState<any>(null);
  const [links, setLinks] = useState<Record<string, string>>({});
  const [text, setText] = useState('');
  const [internal, setInternal] = useState(false);
  const [reason, setReason] = useState('');
  const [code, setCode] = useState('fixed');
  const [note, setNote] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const r = await fetchStaffTicket(id);
      setD(r);
      const entries = await Promise.all((r.attachments as any[]).map(async (a) => [a.id, await evidenceLink(a.path).catch(() => '')] as const));
      setLinks(Object.fromEntries(entries));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [id]);
  useFocusEffect(useCallback(() => { void load(); }, [load]));

  async function run(fn: () => Promise<unknown>, after?: () => void) {
    setBusy(true);
    setError('');
    try { await fn(); after?.(); await load(); } catch (e) { setError(friendlyError(e)); } finally { setBusy(false); }
  }

  if (!d) return <ScrollView style={styles.screen} contentContainerStyle={styles.content}>{error ? <Notice tone="error">{error}</Notice> : <Text style={styles.meta}>Loading…</Text>}</ScrollView>;

  const t = d.ticket;
  const finished = t.status === 'resolved' || t.status === 'closed';
  const mine = t.assigned_to === userId;
  const youEscalated = t.escalated_by === userId;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      <View style={styles.card}>
        <Text style={styles.title}>{t.ref} · {t.subject}</Text>
        <Text style={styles.meta}>{staffStatusLabel(t.status)} · {t.priority} · {d.requester.name} ({d.requester.verification}, {d.requester.account_state})</Text>
        {t.order_ref ? <Text style={styles.meta}>Order {t.order_ref}</Text> : null}
        <Text style={styles.meta}>{t.assigned_name ? `With ${t.assigned_name}` : 'Nobody has taken this yet'} · first reply due {String(t.due_at).slice(0, 16).replace('T', ' ')}</Text>
        {d.requester.other_open_tickets > 0 ? <Text style={styles.meta}>This person has {d.requester.other_open_tickets} other open ticket(s).</Text> : null}
        {t.escalation_reason ? <Text style={styles.meta}>Escalated: {t.escalation_reason}</Text> : null}
        {t.customer_rating ? <Text style={styles.meta}>Customer rated {t.customer_rating}/5{t.customer_comment ? `: ${t.customer_comment}` : ''}</Text> : null}
      </View>

      {(d.messages as any[]).map((m) => (
        <View key={m.id} style={[styles.bubble, m.internal ? styles.note : m.role === 'staff' ? styles.staff : styles.customer]}>
          <Text style={styles.meta}>{m.internal ? 'Internal note' : m.role === 'staff' ? 'Staff' : 'Customer'} · {m.author} · {String(m.at).slice(0, 16).replace('T', ' ')}</Text>
          <Text style={styles.body}>{m.body}</Text>
        </View>
      ))}
      <View style={styles.row}>
        {(d.attachments as any[]).map((a) => (links[a.id] ? <Image key={a.id} source={{ uri: links[a.id] }} style={styles.thumb} /> : null))}
      </View>

      {!finished && !t.assigned_to && !(t.status === 'escalated' && youEscalated) ? (
        <Button title="Take this ticket" loading={busy} onPress={() => run(() => claimTicket(t.id))} />
      ) : null}
      {t.status === 'escalated' && youEscalated ? <Notice>You escalated this one. A different person needs to take it and resolve it.</Notice> : null}

      {!finished && mine ? (
        <>
          <SectionTitle>Reply</SectionTitle>
          <Field label="Message" value={text} onChangeText={setText} multiline style={{ minHeight: 90, textAlignVertical: 'top' }} />
          <View style={styles.rowCenter}>
            <Switch value={internal} onValueChange={setInternal} />
            <Text style={styles.body}>Internal note (the customer will not see it)</Text>
          </View>
          <Button title={internal ? 'Save note' : 'Send to customer'} loading={busy} onPress={() => run(() => staffReply(t.id, text, internal), () => setText(''))} />
          {t.status === 'waiting_on_customer' ? <Button title="Customer replied: back to in progress" variant="secondary" onPress={() => run(() => setTicketStatus(t.id, 'in_progress'))} /> : null}

          <SectionTitle>Resolve</SectionTitle>
          <View style={styles.row}>
            {RESOLUTION_CODES.map((r) => <Chip key={r.key} label={r.label} selected={code === r.key} onPress={() => setCode(r.key)} />)}
          </View>
          <Field label="What was done (the customer will read this)" value={note} onChangeText={setNote} multiline />
          <Button title="Mark resolved" loading={busy} disabled={youEscalated} onPress={() => run(() => resolveTicket(t.id, code, note), () => setNote(''))} />

          {t.status !== 'escalated' ? (
            <>
              <SectionTitle>Need a second person?</SectionTitle>
              <Field label="Why (at least 10 characters)" value={reason} onChangeText={setReason} multiline />
              <Button title="Escalate" variant="secondary" loading={busy} onPress={() => run(() => escalateTicket(t.id, reason), () => setReason(''))} />
            </>
          ) : null}
        </>
      ) : null}

      <SectionTitle>History</SectionTitle>
      {(d.events as any[]).map((e, i) => (
        <Text key={i} style={styles.meta}>{String(e.at).slice(0, 16).replace('T', ' ')} · {e.actor ?? 'system'} · {e.event}</Text>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: 4, borderWidth: 1, borderColor: colors.border },
  title: { fontSize: 18, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.text, lineHeight: 22, flexShrink: 1 },
  meta: { fontSize: 12, color: colors.muted, lineHeight: 18 },
  bubble: { borderRadius: radius.md, padding: spacing.md, gap: 4 },
  customer: { backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  staff: { backgroundColor: colors.primarySoft },
  note: { backgroundColor: colors.warningSoft },
  row: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' },
  rowCenter: { flexDirection: 'row', gap: spacing.sm, alignItems: 'center' },
  thumb: { width: 90, height: 90, borderRadius: radius.sm },
});
