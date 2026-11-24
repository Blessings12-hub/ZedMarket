import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';

import { Button, Chip, Field, Notice, SectionTitle } from '../../../src/components/ui';
import { MONTHS, VISIBILITY_LABELS, birthdayProblem, formatBirthday, type Visibility } from '../../../src/domain/birthdays';
import { fetchMyBirthday, fetchMyEvents, removeMyBirthday, saveMyBirthday, type MyEvent } from '../../../src/features/birthdays/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

export default function MyBirthday() {
  const router = useRouter();
  const [loaded, setLoaded] = useState(false);
  const [has, setHas] = useState(false);
  const [month, setMonth] = useState<number | null>(null);
  const [day, setDay] = useState('');
  const [visibility, setVisibility] = useState<Visibility>('staff');
  const [showPhoto, setShowPhoto] = useState(true);
  const [position, setPosition] = useState('');
  const [events, setEvents] = useState<MyEvent[]>([]);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);
  const [confirmRemove, setConfirmRemove] = useState(false);

  const load = useCallback(async () => {
    try {
      const [b, ev] = await Promise.all([fetchMyBirthday(), fetchMyEvents().catch(() => [])]);
      setHas(b.hasBirthday);
      setMonth(b.month);
      setDay(b.day ? String(b.day) : '');
      setVisibility(b.visibility);
      setShowPhoto(b.showPhoto);
      setPosition(b.position ?? '');
      setEvents(ev);
      setError('');
    } catch (e) {
      setError(friendlyError(e) === 'Not allowed.' ? 'Birthdays need staff access and your two-factor code. Open Staff tools first.' : friendlyError(e));
    } finally {
      setLoaded(true);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  const dayNumber = day.trim() === '' ? null : Number(day);
  const problem = birthdayProblem(month, dayNumber);

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

  if (!loaded) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {notice ? <Notice>{notice}</Notice> : null}
      <Text style={styles.text}>Only your day and month are saved. Your year of birth is never asked for or kept.</Text>

      <SectionTitle>Month</SectionTitle>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.chips}>
        {MONTHS.map((m, i) => (
          <Chip key={m} label={m} selected={month === i + 1} onPress={() => setMonth(i + 1)} />
        ))}
      </ScrollView>
      <Field label="Day of the month" value={day} onChangeText={(v) => setDay(v.replace(/\D/g, '').slice(0, 2))} keyboardType="number-pad" maxLength={2} error={month !== null && day !== '' ? problem ?? undefined : undefined} />
      <Field label="Position or department (optional)" value={position} onChangeText={setPosition} maxLength={80} />

      <SectionTitle>Who can see it</SectionTitle>
      {(Object.keys(VISIBILITY_LABELS) as Visibility[]).map((v) => (
        <Pressable key={v} accessibilityRole="radio" accessibilityState={{ selected: visibility === v }} onPress={() => setVisibility(v)} style={[styles.option, visibility === v && styles.optionOn]}>
          <Text style={styles.optionTitle}>{VISIBILITY_LABELS[v].label}</Text>
          <Text style={styles.hint}>{VISIBILITY_LABELS[v].hint}</Text>
        </Pressable>
      ))}
      <View style={styles.switchRow}>
        <View style={styles.switchText}>
          <Text style={styles.optionTitle}>Show my profile photo</Text>
          <Text style={styles.hint}>If you have none, your initials are shown.</Text>
        </View>
        <Switch accessibilityLabel="Show my profile photo" value={showPhoto} onValueChange={setShowPhoto} />
      </View>
      <Text style={styles.hint}>A birthday you save today starts next time that date comes round, so colleagues are not notified about it today.</Text>

      <Button
        title={has ? 'Save changes' : 'Save my birthday'}
        loading={busy}
        disabled={!!problem}
        onPress={() => run(async () => { await saveMyBirthday({ month: month!, day: dayNumber!, visibility, showPhoto, position }); setNotice('Saved.'); })}
      />

      {has && month && dayNumber ? (
        confirmRemove ? (
          <View style={styles.box}>
            <Text style={styles.text}>Remove {formatBirthday(month, dayNumber)} from the staff calendar? Your old message boards are kept.</Text>
            <Button title="Yes, remove it" variant="danger" loading={busy} onPress={() => run(async () => { await removeMyBirthday(); setConfirmRemove(false); setNotice('Removed.'); })} />
            <Button title="Keep it" variant="secondary" disabled={busy} onPress={() => setConfirmRemove(false)} />
          </View>
        ) : (
          <Button title="Remove my birthday" variant="danger" onPress={() => setConfirmRemove(true)} />
        )
      ) : null}

      <SectionTitle>My past birthday boards</SectionTitle>
      {events.length === 0 ? <Text style={styles.text}>No boards yet.</Text> : null}
      {events.map((e) => (
        <Pressable key={e.eventId} accessibilityRole="button" onPress={() => router.push(`/admin/birthdays/${e.eventId}`)} style={styles.option}>
          <Text style={styles.optionTitle}>{e.eventDate}</Text>
          <Text style={styles.hint}>{e.messageCount} wish{e.messageCount === 1 ? '' : 'es'}</Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, justifyContent: 'center', backgroundColor: colors.background },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  chips: { gap: spacing.sm, paddingVertical: spacing.xs },
  option: { gap: 2, padding: spacing.md, borderRadius: radius.md, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  optionOn: { borderColor: colors.primary, backgroundColor: colors.primarySoft },
  optionTitle: { fontSize: 15, fontWeight: '600', color: colors.text },
  hint: { fontSize: 13, lineHeight: 18, color: colors.muted },
  switchRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  switchText: { flex: 1, gap: 2 },
  box: { gap: spacing.sm, padding: spacing.md, borderRadius: radius.md, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
});
