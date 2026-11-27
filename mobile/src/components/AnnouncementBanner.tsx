import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { fetchAnnouncements, trackAnnouncement, type PublicAnnouncement } from '../features/media/api';
import { colors, radius, spacing } from '../theme';

// The newest published announcement, at the top of Home. Quiet when there is none or it cannot load.
export function AnnouncementBanner({ signedIn }: { signedIn: boolean }) {
  const router = useRouter();
  const [item, setItem] = useState<PublicAnnouncement | null>(null);
  const [hidden, setHidden] = useState(false);

  useEffect(() => {
    let live = true;
    fetchAnnouncements().then((rows) => { if (live) setItem(rows[0] ?? null); }).catch(() => undefined);
    return () => { live = false; };
  }, []);

  if (!item || hidden) return null;
  return (
    <View style={styles.box}>
      <Pressable
        accessibilityRole="button"
        style={{ flex: 1 }}
        onPress={() => { if (signedIn) void trackAnnouncement(item.id, 'click'); router.push('/announcements' as never); }}
      >
        <Text style={styles.title} numberOfLines={1}>{item.title}</Text>
        {item.body ? <Text style={styles.body} numberOfLines={2}>{item.body}</Text> : null}
      </Pressable>
      <Pressable accessibilityRole="button" accessibilityLabel="Hide this announcement" onPress={() => setHidden(true)} hitSlop={10}>
        <Text style={styles.close}>✕</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  box: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, backgroundColor: colors.primarySoft, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, marginHorizontal: spacing.lg, marginTop: spacing.sm },
  title: { fontSize: 14, fontWeight: '700', color: colors.primaryDark },
  body: { fontSize: 13, color: colors.text, marginTop: 2 },
  close: { fontSize: 16, color: colors.muted },
});
