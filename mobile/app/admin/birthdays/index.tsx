import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../../src/auth/AuthProvider';
import { Button, Chip, Notice, SectionTitle } from '../../../src/components/ui';
import { canManageTeam, canModerate } from '../../../src/domain/admin';
import { MONTHS, daysUntilLabel, formatBirthday } from '../../../src/domain/birthdays';
import { fetchMyRoles } from '../../../src/features/admin/api';
import { Avatar } from '../../../src/features/birthdays/Avatar';
import { fetchMonth, fetchToday, fetchUpcoming, type Celebrant, type MonthEntry, type Upcoming } from '../../../src/features/birthdays/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

export default function BirthdaysHome() {
  const router = useRouter();
  const { userId } = useAuth();
  const [month, setMonth] = useState(new Date().getMonth() + 1);
  const [today, setToday] = useState<Celebrant[] | null>(null);
  const [upcoming, setUpcoming] = useState<Upcoming[]>([]);
  const [entries, setEntries] = useState<MonthEntry[] | null>(null);
  const [canModerateWishes, setCanModerateWishes] = useState(false);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    try {
      setError('');
      const [t, u] = await Promise.all([fetchToday(), fetchUpcoming(30)]);
      setToday(t);
      setUpcoming(u);
      if (userId) {
        const roles = await fetchMyRoles(userId).catch(() => []);
        setCanModerateWishes(canModerate(roles) || canManageTeam(roles));
      }
    } catch (e) {
      setToday([]);
      setError(friendlyError(e) === 'Not allowed.' ? 'Birthdays need staff access and your two-factor code. Open Staff tools first.' : friendlyError(e));
    }
  }, [userId]);

  const loadMonth = useCallback(async (m: number) => {
    try {
      setEntries(null);
      setEntries(await fetchMonth(m));
    } catch (e) {
      setEntries([]);
      setError(friendlyError(e));
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void load();
      void loadMonth(month);
    }, [load, loadMonth, month]),
  );

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.title}>Staff birthdays</Text>
      <Text style={styles.text}>Only the day and month are kept. Staff can hide their own birthday.</Text>
      <View style={styles.row}>
        <Button title="My birthday" variant="secondary" onPress={() => router.push('/admin/birthdays/mine')} />
        {canModerateWishes ? <Button title="Reported wishes" variant="secondary" onPress={() => router.push('/admin/birthdays/reports')} /> : null}
      </View>

      <SectionTitle>Today</SectionTitle>
      {today === null ? <ActivityIndicator color={colors.primary} /> : null}
      {today && today.length === 0 && !error ? <Text style={styles.text}>Nobody has a birthday today.</Text> : null}
      {today?.map((c) => (
        <Pressable
          key={c.userId}
          accessibilityRole="button"
          accessibilityLabel={`${c.name}'s birthday today${c.eventId ? ', open the message board' : ''}`}
          disabled={!c.eventId}
          onPress={() => c.eventId && router.push(`/admin/birthdays/${c.eventId}`)}
          style={styles.card}
        >
          <Avatar name={c.name} path={c.avatarPath} />
          <View style={styles.cardText}>
            <Text style={styles.name}>{c.name}{c.isMe ? ' (you)' : ''}</Text>
            {c.position ? <Text style={styles.meta}>{c.position}</Text> : null}
            <Text style={styles.action}>
              {c.eventId ? `Message board · ${c.messageCount} wish${c.messageCount === 1 ? '' : 'es'}` : 'The board opens shortly'}
            </Text>
          </View>
        </Pressable>
      ))}

      <SectionTitle>Coming up (next 30 days)</SectionTitle>
      {upcoming.length === 0 && today !== null && !error ? <Text style={styles.text}>No birthdays in the next 30 days.</Text> : null}
      {upcoming.map((u) => (
        <View key={u.userId} style={styles.card}>
          <Avatar name={u.name} path={u.avatarPath} />
          <View style={styles.cardText}>
            <Text style={styles.name}>{u.name}</Text>
            {u.position ? <Text style={styles.meta}>{u.position}</Text> : null}
            <Text style={styles.meta}>{formatBirthday(u.month, u.day)} · {daysUntilLabel(u.daysUntil)}</Text>
          </View>
        </View>
      ))}

      <SectionTitle>Calendar</SectionTitle>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.chips}>
        {MONTHS.map((m, i) => (
          <Chip key={m} label={m} selected={month === i + 1} onPress={() => setMonth(i + 1)} />
        ))}
      </ScrollView>
      {entries === null ? <ActivityIndicator color={colors.primary} /> : null}
      {entries && entries.length === 0 ? <Text style={styles.text}>No birthdays in {MONTHS[month - 1]}.</Text> : null}
      {entries?.map((e) => (
        <View key={e.userId} style={styles.card}>
          <Avatar name={e.name} path={e.avatarPath} size={36} />
          <View style={styles.cardText}>
            <Text style={styles.name}>{formatBirthday(e.month, e.day)} · {e.name}</Text>
            {e.position ? <Text style={styles.meta}>{e.position}</Text> : null}
          </View>
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  row: { gap: spacing.sm },
  chips: { gap: spacing.sm, paddingVertical: spacing.xs },
  card: { flexDirection: 'row', alignItems: 'center', gap: spacing.md, padding: spacing.md, borderRadius: radius.md, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  cardText: { flex: 1, gap: 2 },
  name: { fontSize: 16, fontWeight: '700', color: colors.text },
  meta: { fontSize: 14, color: colors.muted },
  action: { fontSize: 14, fontWeight: '600', color: colors.primary },
});
