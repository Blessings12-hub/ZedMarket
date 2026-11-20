import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Notice } from '../../src/components/ui';
import { listConversations, type ConversationSummary } from '../../src/features/chat/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, spacing } from '../../src/theme';

export default function MessagesScreen() {
  const router = useRouter();
  const { userId } = useAuth();
  const [items, setItems] = useState<ConversationSummary[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      setItems(await listConversations(userId));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoading(false);
    }
  }, [userId]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  return (
    <View style={styles.screen}>
      {error ? (
        <View style={{ padding: spacing.lg }}>
          <Notice tone="error">{error}</Notice>
        </View>
      ) : null}
      <FlatList
        data={items}
        keyExtractor={(item) => item.id}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ flexGrow: 1 }}
        renderItem={({ item }) => (
          <Pressable accessibilityRole="button" style={styles.row} onPress={() => router.push(`/chat/${item.id}`)}>
            <Text style={styles.name}>{item.otherName}</Text>
            <Text style={styles.listing} numberOfLines={1}>
              {item.listingTitle}
            </Text>
          </Pressable>
        )}
        ListEmptyComponent={
          loading ? null : (
            <View style={styles.empty}>
              <Text style={styles.emptyTitle}>No messages yet</Text>
              <Text style={styles.emptyText}>Open a listing and tap Message seller to start a chat.</Text>
            </View>
          )
        }
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  row: { padding: spacing.lg, backgroundColor: colors.surface, borderBottomWidth: 1, borderBottomColor: colors.border, gap: 2 },
  name: { fontSize: 16, fontWeight: '600', color: colors.text },
  listing: { fontSize: 14, color: colors.muted },
  empty: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl, gap: spacing.xs },
  emptyTitle: { fontSize: 18, fontWeight: '600', color: colors.text },
  emptyText: { color: colors.muted, textAlign: 'center' },
});
