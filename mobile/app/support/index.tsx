import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text } from 'react-native';

import { Button, Notice } from '../../src/components/ui';
import { customerStatusLabel } from '../../src/domain/support';
import { fetchMyTickets, type MyTicket } from '../../src/features/support/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function SupportHome() {
  const router = useRouter();
  const [items, setItems] = useState<MyTicket[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState('');

  useFocusEffect(
    useCallback(() => {
      fetchMyTickets()
        .then((r) => { setItems(r); setError(''); })
        .catch((e) => setError(friendlyError(e)))
        .finally(() => setLoaded(true));
    }, []),
  );

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Button title="Ask for help" onPress={() => router.push('/support/new')} />
      {loaded && items.length === 0 ? <Text style={styles.empty}>You have not asked for help yet.</Text> : null}
      {items.map((t) => (
        <Pressable key={t.id} style={[styles.card, t.unreadReply && styles.unread]} onPress={() => router.push(`/support/${t.id}`)} accessibilityRole="button">
          <Text style={styles.title}>{t.subject}</Text>
          <Text style={styles.meta}>{t.ref} · {customerStatusLabel(t.status)}{t.unreadReply ? ' · New reply' : ''}</Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  empty: { color: colors.muted, textAlign: 'center', marginTop: spacing.xl },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: 4, borderWidth: 1, borderColor: colors.border },
  unread: { borderColor: colors.primary },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
});
