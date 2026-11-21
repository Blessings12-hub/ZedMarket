import AsyncStorage from '@react-native-async-storage/async-storage';
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Alert, FlatList, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { FilterSheet } from '../../src/components/FilterSheet';
import { ListingCard } from '../../src/components/ListingCard';
import { ListingRail } from '../../src/components/ListingRail';
import { Chip, Notice } from '../../src/components/ui';
import { describeSearch } from '../../src/domain/search';
import {
  clearRecentlyViewed,
  fetchFeatured,
  fetchListings,
  fetchNearby,
  fetchRecentlyViewed,
  fetchRecommended,
  fetchTrending,
  loadReferenceData,
  PAGE_SIZE,
  saveSearch,
} from '../../src/features/listings/api';
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

const NEARBY_KEY = 'zedmarket.nearbyLocation';

type Rails = {
  featured: ListingSummary[];
  trending: ListingSummary[];
  recommended: ListingSummary[];
  recent: ListingSummary[];
  nearby: ListingSummary[];
};
const emptyRails: Rails = { featured: [], trending: [], recommended: [], recent: [], nearby: [] };

// One rail failing (for example on a weak connection) must not hide the others.
const safely = (p: Promise<ListingSummary[]>) => p.catch(() => [] as ListingSummary[]);

export default function BrowseScreen() {
  const router = useRouter();
  const { session } = useAuth();
  const signedIn = !!session;

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

  const [rails, setRails] = useState<Rails>(emptyRails);
  const [nearbyId, setNearbyId] = useState<number | null>(null);

  useEffect(() => {
    loadReferenceData()
      .then((ref) => {
        setCategories(ref.categories);
        setLocations(ref.locations);
      })
      .catch((e) => setError(friendlyError(e)));
    AsyncStorage.getItem(NEARBY_KEY)
      .then((v) => {
        const id = v ? Number(v) : NaN;
        if (Number.isInteger(id)) setNearbyId(id);
      })
      .catch(() => undefined);
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

  // Rails refresh every time the tab comes back into view, so "recently viewed" is current.
  const loadRails = useCallback(async () => {
    const [featured, trending, recommended, recent, nearby] = await Promise.all([
      safely(fetchFeatured()),
      safely(fetchTrending()),
      signedIn ? safely(fetchRecommended()) : Promise.resolve([]),
      signedIn ? safely(fetchRecentlyViewed()) : Promise.resolve([]),
      nearbyId !== null ? safely(fetchNearby(nearbyId)) : Promise.resolve([]),
    ]);
    setRails({ featured, trending, recommended, recent, nearby });
  }, [signedIn, nearbyId]);

  useFocusEffect(
    useCallback(() => {
      void loadRails();
    }, [loadRails]),
  );

  function chooseNearby(id: number) {
    setNearbyId(id);
    AsyncStorage.setItem(NEARBY_KEY, String(id)).catch(() => undefined);
  }

  async function clearHistory() {
    try {
      await clearRecentlyViewed();
      setRails((r) => ({ ...r, recent: [] }));
    } catch (e) {
      Alert.alert('Could not clear your history', friendlyError(e));
    }
  }

  const activeFilters = countActiveFilters(filters);
  const searching = debouncedTerm.trim().length >= 2 || activeFilters > 0;
  const canSaveSearch = debouncedTerm.trim().length >= 2 || filters.categoryId !== null || filters.locationId !== null ||
    filters.conditions.length > 0 || filters.minPrice !== '' || filters.maxPrice !== '';

  async function onSaveSearch() {
    if (!signedIn) {
      router.push('/sign-in');
      return;
    }
    const name = describeSearch({
      term: debouncedTerm,
      categoryName: categories.find((c) => c.id === filters.categoryId)?.name,
      areaName: locations.find((l) => l.id === filters.locationId)?.area,
      minPrice: filters.minPrice ? Number(filters.minPrice) : null,
      maxPrice: filters.maxPrice ? Number(filters.maxPrice) : null,
    });
    try {
      await saveSearch(name, debouncedTerm, filters);
      Alert.alert('Search saved', 'You will see new matching items under Alerts in your account.');
    } catch (e) {
      Alert.alert('Could not save this search', friendlyError(e));
    }
  }

  const areas = locations.filter((l) => l.area);

  const header = (
    <View>
      {searching && canSaveSearch ? (
        <Pressable accessibilityRole="button" onPress={onSaveSearch} style={styles.saveRow}>
          <Text style={styles.saveText}>Alert me about new matches</Text>
        </Pressable>
      ) : null}

      {!searching ? (
        <View style={{ paddingTop: spacing.sm }}>
          <ListingRail title="Featured" note="Picked by the ZedMarket team" items={rails.featured} />
          <ListingRail title="Recommended for you" note="Based on what you have looked at and saved" items={rails.recommended} />
          <ListingRail title="Trending this week" items={rails.trending} />
          <ListingRail
            title="Recently viewed"
            items={rails.recent}
            action={
              <Pressable accessibilityRole="button" onPress={clearHistory}>
                <Text style={styles.link}>Clear</Text>
              </Pressable>
            }
          />

          <View style={styles.nearbyHead}>
            <Text style={styles.railTitle}>Near you</Text>
            <Text style={styles.railNote}>
              {nearbyId === null ? 'Pick your area to see items in your town' : 'Items in your town, your area first'}
            </Text>
          </View>
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.chipRow}>
            {areas.map((l) => (
              <Chip key={l.id} label={l.area ?? ''} selected={nearbyId === l.id} onPress={() => chooseNearby(l.id)} />
            ))}
          </ScrollView>
          <ListingRail title="" items={rails.nearby} />

          <Text style={styles.allTitle}>All listings</Text>
        </View>
      ) : null}
    </View>
  );

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
        columnWrapperStyle={{ gap: spacing.md, paddingHorizontal: spacing.lg }}
        contentContainerStyle={{ gap: spacing.md, paddingBottom: spacing.xl }}
        ListHeaderComponent={header}
        renderItem={({ item }) => <ListingCard listing={item} />}
        onEndReached={() => {
          if (!loading && !finished) load(page + 1, false);
        }}
        onEndReachedThreshold={0.4}
        refreshing={loading && page === 0}
        onRefresh={() => {
          void load(0, true);
          void loadRails();
        }}
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
  saveRow: { paddingHorizontal: spacing.lg, paddingBottom: spacing.sm },
  saveText: { color: colors.primary, fontWeight: '600', textDecorationLine: 'underline' },
  link: { color: colors.primary, fontWeight: '600' },
  nearbyHead: { paddingHorizontal: spacing.lg, marginBottom: spacing.xs },
  railTitle: { fontSize: 18, fontWeight: '700', color: colors.text },
  railNote: { fontSize: 12, color: colors.muted },
  chipRow: { paddingHorizontal: spacing.lg, gap: spacing.sm, paddingBottom: spacing.sm },
  allTitle: { fontSize: 18, fontWeight: '700', color: colors.text, paddingHorizontal: spacing.lg, marginBottom: spacing.sm },
  empty: { alignItems: 'center', padding: spacing.xl, gap: spacing.xs },
  emptyTitle: { fontSize: 18, fontWeight: '600', color: colors.text },
  emptyText: { color: colors.muted },
});
