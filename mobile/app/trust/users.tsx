import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Field, Notice, VerifiedBadge } from '../../src/components/ui';
import { USER_FILTER_LABELS, type UserFilter } from '../../src/domain/trustAdmin';
import { PAGE_SIZE, fetchTrustUsers, type TrustUser } from '../../src/features/trust-admin/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

const FILTERS: UserFilter[] = ['verified', 'suspended', 'restricted', 'all'];

export default function Users() {
  const router = useRouter();
  const params = useLocalSearchParams<{ filter?: string }>();
  const [filter, setFilter] = useState<UserFilter>(FILTERS.includes(params.filter as UserFilter) ? (params.filter as UserFilter) : 'all');
  const [search, setSearch] = useState('');
  const [items, setItems] = useState<TrustUser[]>([]);
  const [more, setMore] = useState(false);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(
    async (offset = 0) => {
      try {
        const page = await fetchTrustUsers(filter, search, offset);
        setItems((current) => (offset === 0 ? page : [...current, ...page]));
        setMore(page.length === PAGE_SIZE);
        setError('');
      } catch (e) {
        setError(friendlyError(e));
      } finally {
        setLoading(false);
      }
    },
    [filter, search],
  );

  useFocusEffect(
    useCallback(() => {
      setLoading(true);
      load(0);
    }, [load]),
  );

  return (
    <View style={styles.screen}>
      <View style={styles.filters}>
        <View style={styles.row}>
          {FILTERS.map((f) => (
            <Chip key={f} label={USER_FILTER_LABELS[f]} selected={filter === f} onPress={() => setFilter(f)} />
          ))}
        </View>
        <Field label="Search by name" value={search} onChangeText={setSearch} onSubmitEditing={() => load(0)} returnKeyType="search" />
        {error ? <Notice tone="error">{error}</Notice> : null}
      </View>
      <FlatList
        data={items}
        keyExtractor={(u) => u.id}
        refreshing={loading}
        onRefresh={() => load(0)}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.sm, flexGrow: 1 }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>No one matches.</Text>}
        ListFooterComponent={more ? <Button title="Load more" variant="secondary" onPress={() => load(items.length)} /> : null}
        renderItem={({ item }) => (
          <Pressable
            accessibilityRole="button"
            onPress={() => router.push({ pathname: '/trust/user/[id]', params: { id: item.id } })}
            style={styles.card}
          >
            <View style={styles.row}>
              <Text style={styles.name}>{item.displayName}</Text>
              <VerifiedBadge level={item.verificationLevel} />
            </View>
            <Text style={styles.meta}>
              {item.accountState === 'active' ? 'Active' : item.accountState === 'suspended' ? 'Suspended' : 'Restricted'} · joined{' '}
              {new Date(item.joinedAt).toLocaleDateString()}
            </Text>
            {item.stateReason ? <Text style={styles.meta}>Reason: {item.stateReason}</Text> : null}
          </Pressable>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  filters: { padding: spacing.lg, gap: spacing.sm },
  row: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap', alignItems: 'center' },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: 4 },
  name: { fontSize: 16, fontWeight: '600', color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
