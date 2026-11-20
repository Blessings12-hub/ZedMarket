import { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, FlatList, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { FilterSheet } from '../../src/components/FilterSheet';
import { ListingCard } from '../../src/components/ListingCard';
import { Notice } from '../../src/components/ui';
import { fetchListings, loadReferenceData, PAGE_SIZE } from '../../src/features/listings/api';
import {
  countActiveFilters,
  defaultFilters,
  type Category,
  type Filters,
  type ListingSummary,
  type Location,
} from '../../src/features/listings/types';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function BrowseScreen() {
  const [term, setTerm] = useState('');
  const [debouncedTerm, setDebouncedTerm] = useState('');
  const [filters, setFilters] = useState<Filters>(defaultFilters);
  const [filtersOpen, setFiltersOpen] = useState(false);
  const [categories, setCategories] = useState<Category[]>([]);
  const [locations, setLocations] = useState<Location[]>([]);

  const [items, setItems] = useState<ListingSummary[]>([]);
  const [page, setPage] = useState(0);
  const [finished, setFinished] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const latestRequest = useRef(0);

  useEffect(() => {
    loadReferenceData()
      .then((ref) => {
        setCategories(ref.categories);
        setLocations(ref.locations);
      })
      .catch((e) => setError(friendlyError(e)));
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedTerm(term), 350);
    return () => clearTimeout(timer);
  }, [term]);

  const load = useCallback(
    async (nextPage: number, replace: boolean) => {
      const request = ++latestRequest.current;
      setLoading(true);
      setError('');
      try {
        const rows = await fetchListings(debouncedTerm, filters, nextPage);
        if (request !== latestRequest.current) return;
        setItems((prev) => (replace ? rows : [...prev, ...rows]));
        setPage(nextPage);
        setFinished(rows.length < PAGE_SIZE);
      } catch (e) {
        if (request === latestRequest.current) setError(friendlyError(e));
      } finally {
        if (request === latestRequest.current) setLoading(false);
      }
    },
    [debouncedTerm, filters],
  );

  useEffect(() => {
    load(0, true);
  }, [load]);

  const activeFilters = countActiveFilters(filters);

  return (
    <View style={styles.screen}>
      <View style={styles.searchRow}>
        <TextInput
          value={term}
          onChangeText={setTerm}
          placeholder="Search phones, sofas, dresses"
          placeholderTextColor={colors.muted}
          style={styles.search}
          returnKeyType="search"
          autoCapitalize="none"
          maxLength={60}
        />
        <Pressable accessibilityRole="button" style={styles.filterButton} onPress={() => setFiltersOpen(true)}>
          <Text style={styles.filterText}>Filters{activeFilters > 0 ? ` (${activeFilters})` : ''}</Text>
        </Pressable>
      </View>

      {error ? (
        <View style={{ padding: spacing.lg }}>
          <Notice tone="error">{error}</Notice>
        </View>
      ) : null}

      <FlatList
        data={items}
        keyExtractor={(item) => item.id}
        numColumns={2}
        columnWrapperStyle={{ gap: spacing.md }}
        contentContainerStyle={styles.list}
        renderItem={({ item }) => <ListingCard listing={item} />}
        onEndReached={() => {
          if (!loading && !finished) load(page + 1, false);
        }}
        onEndReachedThreshold={0.4}
        refreshing={loading && page === 0}
        onRefresh={() => load(0, true)}
        ListEmptyComponent={
          loading ? null : (
            <View style={styles.empty}>
              <Text style={styles.emptyTitle}>Nothing found</Text>
              <Text style={styles.emptyText}>Try a different word or clear some filters.</Text>
            </View>
          )
        }
        ListFooterComponent={loading && page > 0 ? <ActivityIndicator color={colors.primary} style={{ margin: spacing.lg }} /> : null}
      />

      <FilterSheet
        visible={filtersOpen}
        filters={filters}
        categories={categories}
        locations={locations}
        onClose={() => setFiltersOpen(false)}
        onApply={(next) => {
          setFilters(next);
          setFiltersOpen(false);
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  searchRow: { flexDirection: 'row', gap: spacing.sm, padding: spacing.lg, paddingBottom: spacing.sm },
  search: {
    flex: 1,
    minHeight: 46,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.md,
    backgroundColor: colors.surface,
    paddingHorizontal: spacing.md,
    fontSize: 16,
    color: colors.text,
  },
  filterButton: {
    minHeight: 46,
    justifyContent: 'center',
    paddingHorizontal: spacing.md,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  filterText: { color: colors.primary, fontWeight: '600' },
  list: { padding: spacing.lg, gap: spacing.md },
  empty: { alignItems: 'center', padding: spacing.xl, gap: spacing.xs },
  emptyTitle: { fontSize: 18, fontWeight: '600', color: colors.text },
  emptyText: { color: colors.muted },
});
