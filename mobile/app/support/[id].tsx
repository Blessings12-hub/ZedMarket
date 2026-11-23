import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice } from '../../src/components/ui';
import {
  MAX_ATTACHMENTS, customerCanRate, customerCanReply, customerStatusLabel, resolutionLabel,
} from '../../src/domain/support';
import {
  attachPhoto, closeMyTicket, evidenceLink, fetchTicket, rateTicket, replyToTicket,
  type TicketDetail, type TicketMessage,
} from '../../src/features/support/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function TicketScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { userId } = useAuth();
  const [ticket, setTicket] = useState<TicketDetail | null>(null);
  const [messages, setMessages] = useState<TicketMessage[]>([]);
  const [files, setFiles] = useState<{ id: string; path: string }[]>([]);
  const [links, setLinks] = useState<Record<string, string>>({});
  const [text, setText] = useState('');
  const [comment, setComment] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const r = await fetchTicket(id);
      setTicket(r.ticket);
      setMessages(r.messages);
      setFiles(r.files);
      const entries = await Promise.all(r.files.map(async (f) => [f.id, await evidenceLink(f.path).catch(() => '')] as const));
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
    try {
      await fn();
      after?.();
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!ticket) return <ScrollView style={styles.screen} contentContainerStyle={styles.content}>{error ? <Notice tone="error">{error}</Notice> : <Text style={styles.meta}>Loading…</Text>}</ScrollView>;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.title}>{ticket.subject}</Text>
      <Text style={styles.status}>{ticket.ref} · {customerStatusLabel(ticket.status)}</Text>

      {ticket.status === 'resolved' || ticket.status === 'closed' ? (
        <View style={styles.card}>
          <Text style={styles.bold}>{resolutionLabel(ticket.resolutionCode)}</Text>
          {ticket.resolutionNote ? <Text style={styles.body}>{ticket.resolutionNote}</Text> : null}
          {ticket.status === 'resolved' ? <Text style={styles.meta}>Not sorted? Reply below within a week and we will look again.</Text> : null}
        </View>
      ) : null}

      {messages.map((m) => (
        <View key={m.id} style={[styles.bubble, m.role === 'staff' ? styles.staff : styles.mine]}>
          <Text style={styles.meta}>{m.role === 'staff' ? 'ZedMarket support' : 'You'} · {m.createdAt.slice(0, 16).replace('T', ' ')}</Text>
          <Text style={styles.body}>{m.body}</Text>
        </View>
      ))}

      {files.length > 0 ? <Text style={styles.bold}>Your photos</Text> : null}
      <View style={styles.row}>
        {files.map((f) => (links[f.id] ? <Image key={f.id} source={{ uri: links[f.id] }} style={styles.thumb} /> : null))}
      </View>

      {customerCanReply(ticket.status) ? (
        <>
          <Field label="Your message" value={text} onChangeText={setText} multiline maxLength={2000} style={{ minHeight: 90, textAlignVertical: 'top' }} />
          <Button title="Send" loading={busy} onPress={() => run(() => replyToTicket(ticket.id, text), () => setText(''))} />
          {files.length < MAX_ATTACHMENTS && userId ? (
            <Button title="Add a photo" variant="secondary" loading={busy} onPress={() => run(() => attachPhoto(userId, ticket.id))} />
          ) : null}
          <Button title="I no longer need help" variant="secondary" loading={busy} onPress={() => run(() => closeMyTicket(ticket.id))} />
        </>
      ) : (
        <Notice>This ticket is closed. If you still need help, ask for help again from the Help page.</Notice>
      )}

      {customerCanRate(ticket.status, ticket.resolutionCode, ticket.rating) ? (
        <View style={styles.card}>
          <Text style={styles.bold}>How did we do?</Text>
          <View style={styles.row}>
            {[1, 2, 3, 4, 5].map((n) => (
              <Chip key={n} label={`${n}`} selected={false} onPress={() => run(() => rateTicket(ticket.id, n, comment))} />
            ))}
          </View>
          <Field label="Comment (optional)" value={comment} onChangeText={setComment} maxLength={500} />
        </View>
      ) : null}
      {ticket.rating ? <Text style={styles.meta}>You rated this {ticket.rating} out of 5. Thank you.</Text> : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  title: { fontSize: 20, fontWeight: '700', color: colors.text },
  status: { fontSize: 14, color: colors.primary, fontWeight: '700' },
  bold: { fontSize: 15, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.text, lineHeight: 22 },
  meta: { fontSize: 12, color: colors.muted },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: spacing.sm, borderWidth: 1, borderColor: colors.border },
  bubble: { borderRadius: radius.md, padding: spacing.md, gap: 4, maxWidth: '92%' },
  staff: { backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, alignSelf: 'flex-start' },
  mine: { backgroundColor: colors.primarySoft, alignSelf: 'flex-end' },
  row: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' },
  thumb: { width: 90, height: 90, borderRadius: radius.sm },
});
