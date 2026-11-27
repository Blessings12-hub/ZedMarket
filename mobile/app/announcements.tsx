import { useEffect } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Notice } from '../src/components/ui';
import { fetchAnnouncements, trackAnnouncement } from '../src/features/media/api';
import { useLoad } from '../src/features/media/useLoad';
import { colors, radius, spacing } from '../src/theme';

// Published announcements and notices from the Media team. Open to everyone; the database returns only published ones.
export default function Announcements() {
  const list = useLoad(fetchAnnouncements);
  // One view per announcement each time the list is opened.
  useEffect(() => { (list.data ?? []).forEach((a) => void trackAnnouncement(a.id, 'view')); }, [list.data]);
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {list.error ? (
        <>
          <Notice tone="error">{list.error}</Notice>
          <Button title="Try again" variant="secondary" onPress={() => void list.reload()} />
        </>
      ) : null}
      {list.loading && !list.error ? <ActivityIndicator color={colors.primary} /> : null}
      {(list.data ?? []).map((a) => (
        <View key={a.id} style={styles.card}>
          <Text style={styles.title}>{a.title}</Text>
          <Text style={styles.date}>{new Date(a.published_at).toLocaleDateString('en-GB', { timeZone: 'Africa/Lusaka', day: 'numeric', month: 'long', year: 'numeric' })}</Text>
          {a.body ? <Text style={styles.body}>{a.body}</Text> : null}
        </View>
      ))}
      {list.data && list.data.length === 0 ? <Text style={styles.body}>No announcements right now.</Text> : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 4 },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  date: { fontSize: 12, color: colors.muted },
  body: { fontSize: 15, lineHeight: 22, color: colors.text },
});
