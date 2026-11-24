import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice, SectionTitle } from '../../../src/components/ui';
import { MAX_WISH, boardNote, wishProblem } from '../../../src/domain/birthdays';
import { formatWhen } from '../../../src/domain/voting';
import { Avatar } from '../../../src/features/birthdays/Avatar';
import { fetchBoardEvent, fetchWishes, reportWish, sendWish, type BoardEvent, type Wish } from '../../../src/features/birthdays/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

export default function BirthdayBoard() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [event, setEvent] = useState<BoardEvent | null>(null);
  const [wishes, setWishes] = useState<Wish[]>([]);
  const [text, setText] = useState('');
  const [reporting, setReporting] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const [e, w] = await Promise.all([fetchBoardEvent(id), fetchWishes(id)]);
      setEvent(e);
      setWishes(w);
      setError('');
    } catch (e) {
      setError(friendlyError(e) === 'Not allowed.' ? 'You cannot open this board. Staff boards need staff access and your two-factor code, and some birthdays are private.' : friendlyError(e));
    }
  }, [id]);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError('');
    setNotice('');
    try {
      await action();
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!event) {
    return <View style={styles.center}>{error ? <Notice tone="error">{error}</Notice> : <ActivityIndicator color={colors.primary} />}</View>;
  }

  const problem = text ? wishProblem(text) : null;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {notice ? <Notice>{notice}</Notice> : null}

      <View style={styles.header}>
        <Avatar name={event.name} path={event.avatarPath} size={72} />
        <Text style={styles.title}>{event.iAmBirthdayPerson ? 'Happy birthday!' : `${event.name}'s birthday`}</Text>
        {event.position ? <Text style={styles.meta}>{event.position}</Text> : null}
        <Text style={styles.meta}>{formatWhen(`${event.eventDate}T12:00:00Z`).split(',')[0]}</Text>
      </View>

      <Notice>{boardNote({ isMe: event.iAmBirthdayPerson, canWrite: event.canWrite, written: event.myMessageCount, max: event.maxMessages })}</Notice>

      <SectionTitle>Wishes</SectionTitle>
      {wishes.length === 0 ? <Text style={styles.meta}>No wishes yet.</Text> : null}
      {wishes.map((w) => (
        <View key={w.id} style={styles.wish}>
          <Text style={styles.sender}>{w.isMine ? 'You' : w.senderName}</Text>
          {w.hidden ? <Text style={styles.hidden}>This message was removed by a moderator.</Text> : <Text style={styles.body}>{w.body}</Text>}
          <Text style={styles.meta}>{formatWhen(w.createdAt)}</Text>
          {!w.isMine && !w.hidden ? (
            reporting === w.id ? (
              <View style={styles.reportBox}>
                <Field label="What is wrong with this message?" value={reason} onChangeText={setReason} maxLength={300} />
                <Button
                  title="Send report"
                  loading={busy}
                  disabled={reason.trim().length < 3}
                  onPress={() => run(async () => { await reportWish(w.id, reason.trim()); setReporting(null); setReason(''); setNotice('Thank you. A moderator will look at it.'); })}
                />
                <Button title="Cancel" variant="secondary" disabled={busy} onPress={() => setReporting(null)} />
              </View>
            ) : (
              <Button title="Report this message" variant="secondary" onPress={() => { setReporting(w.id); setReason(''); }} />
            )
          ) : null}
        </View>
      ))}

      {event.canWrite ? (
        <>
          <SectionTitle>Leave a wish</SectionTitle>
          <Field
            label={`Your wish (${text.trim().length}/${MAX_WISH})`}
            value={text}
            onChangeText={setText}
            multiline
            numberOfLines={3}
            maxLength={MAX_WISH}
            error={problem ?? undefined}
            style={styles.multi}
          />
          <Button
            title="Send wish"
            loading={busy}
            disabled={!text.trim() || !!problem}
            onPress={() => run(async () => { await sendWish(event.eventId, text.trim()); setText(''); setNotice('Your wish was sent.'); })}
          />
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, padding: spacing.xl, justifyContent: 'center', backgroundColor: colors.background },
  header: { alignItems: 'center', gap: spacing.xs },
  title: { fontSize: 22, fontWeight: '700', color: colors.text, textAlign: 'center' },
  meta: { fontSize: 14, color: colors.muted },
  wish: { gap: spacing.xs, padding: spacing.md, borderRadius: radius.md, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  sender: { fontSize: 14, fontWeight: '700', color: colors.primary },
  body: { fontSize: 16, lineHeight: 22, color: colors.text },
  hidden: { fontSize: 14, fontStyle: 'italic', color: colors.muted },
  reportBox: { gap: spacing.sm },
  multi: { minHeight: 80, textAlignVertical: 'top' },
});
