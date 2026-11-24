import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { SectionTitle } from '../../src/components/ui';
import type { AdminRole } from '../../src/domain/admin';
import { consoleMenu } from '../../src/domain/console';
import { fetchMyRoles } from '../../src/features/admin/api';
import { colors, radius, spacing } from '../../src/theme';

// Console start page: one card per section this staff member may open.
export default function ConsoleHome() {
  const router = useRouter();
  const { userId } = useAuth();
  const [roles, setRoles] = useState<AdminRole[]>([]);

  useEffect(() => {
    if (userId) fetchMyRoles(userId).then(setRoles).catch(() => setRoles([]));
  }, [userId]);

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Text style={styles.title}>Staff console</Text>
      <Text style={styles.text}>Your roles: {roles.join(', ') || 'none'}. You only see the sections your roles allow.</Text>
      {consoleMenu(roles).map((g) => (
        <View key={g.group} style={styles.group}>
          <SectionTitle>{g.group}</SectionTitle>
          <View style={styles.grid}>
            {g.items.map((i) => (
              <Pressable key={i.key} accessibilityRole="link" style={styles.card} onPress={() => router.push(i.href as never)}>
                <Text style={styles.cardText}>{i.title}</Text>
              </Pressable>
            ))}
          </View>
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  title: { fontSize: 24, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, color: colors.muted },
  group: { gap: spacing.sm },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.md },
  card: { minWidth: 220, flexGrow: 1, backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg },
  cardText: { fontSize: 16, fontWeight: '600', color: colors.primary },
});
