import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';

import { Button, Notice } from '../../src/components/ui';
import { ROLE_EXPLAINED, ROLE_LABELS } from '../../src/domain/business';
import { fetchMyInvitations, respondToInvitation, type Invitation } from '../../src/features/business/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function Invitations() {
  const router = useRouter();
  const [items, setItems] = useState<Invitation[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      setItems(await fetchMyInvitations());
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  async function answer(i: Invitation, accept: boolean) {
    setBusy(i.id);
    try {
      await respondToInvitation(i.id, accept);
      if (accept) router.replace('/business/manage');
      else await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(null);
    }
  }

  return (
    <View style={styles.screen}>
      <View style={{ padding: spacing.lg, gap: spacing.sm }}>
        <Notice>Invitations are matched to your confirmed email address and last 7 days.</Notice>
        {error ? <Notice tone="error">{error}</Notice> : null}
      </View>
      <FlatList
        data={items}
        keyExtractor={(i) => i.id}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.md }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>No invitations right now.</Text>}
        renderItem={({ item }) => (
          <View style={styles.card}>
            <Text style={styles.title}>{item.businessName}</Text>
            <Text style={styles.text}>{item.invitedBy} invited you as {ROLE_LABELS[item.role].toLowerCase()}.</Text>
            <Text style={styles.meta}>{ROLE_EXPLAINED[item.role]}</Text>
            <Text style={styles.meta}>Expires {new Date(item.expiresAt).toLocaleDateString()}</Text>
            <Button title="Join" onPress={() => answer(item, true)} loading={busy === item.id} />
            <Button title="Decline" variant="secondary" onPress={() => answer(item, false)} disabled={busy === item.id} />
          </View>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  title: { fontSize: 17, fontWeight: '600', color: colors.text },
  text: { fontSize: 15, color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
