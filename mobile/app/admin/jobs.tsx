import { useEffect, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { ROLE_LABELS, jobsFor, type AdminRole } from '../../src/domain/admin';
import { useAuth } from '../../src/auth/AuthProvider';
import { fetchMyRoles } from '../../src/features/admin/api';
import { SectionTitle } from '../../src/components/ui';
import { colors, radius, spacing } from '../../src/theme';

export default function RoleJobsScreen() {
  const { userId } = useAuth();
  const [roles, setRoles] = useState<AdminRole[]>([]);
  useEffect(() => {
    if (userId) fetchMyRoles(userId).then(setRoles).catch(() => setRoles([]));
  }, [userId]);
  const groups = jobsFor(roles);
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Text style={styles.title}>Your jobs</Text>
      {groups.length === 0 ? <Text style={styles.text}>This account has no staff role.</Text> : null}
      {groups.map(({ role, jobs }) => (
        <View key={role} style={styles.card}>
          <SectionTitle>{ROLE_LABELS[role]}</SectionTitle>
          <Text style={styles.text}>{jobs.summary}</Text>
          {jobs.enforced.map((j) => (
            <Text key={j} style={styles.item}>{`• ${j}`}</Text>
          ))}
          {jobs.coming.length > 0 ? <Text style={styles.soon}>Not built yet</Text> : null}
          {jobs.coming.map((j) => (
            <Text key={j} style={styles.itemSoon}>{`• ${j}`}</Text>
          ))}
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
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  item: { fontSize: 15, lineHeight: 22, color: colors.text },
  soon: { fontSize: 13, fontWeight: '700', color: colors.muted, marginTop: spacing.sm },
  itemSoon: { fontSize: 15, lineHeight: 22, color: colors.muted },
});
