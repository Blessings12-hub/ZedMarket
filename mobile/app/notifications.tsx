import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../src/auth/AuthProvider';
import { Button, Chip, Notice } from '../src/components/ui';
import { CATEGORIES, categoryLabel, relativeTime, routeForNotification } from '../src/domain/notifications';
import {
  fetchNotifications,
  markAllRead,
  markRead,
  watchNotifications,
  type AppNotification,
} from '../src/features/notifications/api';
import { friendlyError } from '../src/lib/errors';
import { colors, radius, spacing } from '../src/theme';

export default function NotificationsScreen() {
  const router = useRouter();
  const { userId } = useAuth();
  const [category, setCategory] = useState<string | null>(null);
  const [items, setItems] = useState<AppNotification[]>([]);
  const [error, setError] = useState('');
  const [loaded, setLoaded] = useState(false);

  const load = useCallback(async () => {
    try {
      setItems(await fetchNotifications(category));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoaded(true);
    }
  }, [category]);

  useFocusEffect(
    useCallback(() => {
      void load();
      if (!userId) return undefined;
      return watchNotifications(userId, () => void load());
    }, [load, userId]),
  );

  async function open(n: AppNotification) {
    if (!n.read) {
      setItems((prev) => prev.map((x) => (x.id === n.id ? { ...x, read: true } : x)));
      await markRead([n.id]).catch(() => undefined);
    }
    const route = routeForNotification(n.link);
    if (route) router.push(route as never);
  }

  async function readAll() {
    try {
      await markAllRead(category);
      await load();
    } catch (e) {
      setError(friendlyError(e));
    }
  }

  const unread = items.filter((i) => !i.read).length;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.chips}>
        <Chip label="All" selected={category === null} onPress={() => setCategory(null)} />
        {CATEGORIES.map((c) => (
          <Chip key={c.key} label={c.label} selected={category === c.key} onPress={() => setCategory(c.key)} />
        ))}
      </ScrollView>
      <View style={styles.row}>
        {unread > 0 ? <Button title={`Mark ${unread} as read`} variant="secondary" onPress={readAll} /> : null}
        <Button title="Settings" variant="secondary" onPress={() => router.push('/notification-settings')} />
      </View>
      {loaded && items.length === 0 ? <Text style={styles.empty}>Nothing here yet.</Text> : null}
      {items.map((n) => (
        <Pressable key={n.id} onPress={() => open(n)} style={[styles.card, !n.read && styles.unread]} accessibilityRole="button">
          <Text style={styles.meta}>
            {categoryLabel(n.category)} · {relativeTime(n.createdAt)}
          </Text>
          <Text style={[styles.title, !n.read && styles.bold]}>{n.title}</Text>
          {n.body ? <Text style={styles.body}>{n.body}</Text> : null}
        </Pressable>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  chips: { gap: spacing.sm },
  row: { gap: spacing.sm },
  empty: { color: colors.muted, textAlign: 'center', marginTop: spacing.xl },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: 4, borderWidth: 1, borderColor: colors.border },
  unread: { borderColor: colors.primary },
  meta: { color: colors.muted, fontSize: 12 },
  title: { color: colors.text, fontSize: 15 },
  bold: { fontWeight: '700' },
  body: { color: colors.muted, fontSize: 14 },
});
