import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Ionicons } from '@expo/vector-icons';
import { ActivityIndicator, FlatList, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { AnnouncementBanner } from '../../src/components/AnnouncementBanner';
import { AreaSheet } from '../../src/components/AreaSheet';
import { DeliveryBar } from '../../src/components/DeliveryBar';
import { FilterSheet } from '../../src/components/FilterSheet';
import { ListingCard } from '../../src/components/ListingCard';
import { ListingRail } from '../../src/components/ListingRail';
import { Notice } from '../../src/components/ui';
import type { Place } from '../../src/domain/locations';
import { describeSearch } from '../../src/domain/search';
import {
  clearRecentlyViewed,
  fetchFeatured,
  fetchPromoted,
  fetchListings,
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
import { browseLabel, deliveryShort, pickDeliveryAddress, provinceFor, validArea } from '../../src/features/listings/area';
import { listMyAddresses, loadPlaces, type SavedAddress } from '../../src/features/locations/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';
import { showAlert } from '../../src/lib/dialog';

type Rails = {
  promoted: ListingSummary[];
  featured: ListingSummary[];
  trending: ListingSummary[];
  recommended: ListingSummary[];
  recent: ListingSummary[];
};
const emptyRails: Rails = { promoted: [], featured: [], trending: [], recommended: [], recent: [] };

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
  const [places, setPlaces] = useState<Place[]>([]);
  const [myAddress, setMyAddress] = useState<SavedAddress | null>(null);
  const [areaOpen, setAreaOpen] = useState(false);
  // Everything is shown for the whole province (Lusaka by default, or where the person's delivery location is).
  const province = provinceFor(places, myAddress?.locationId);

  useEffect(() => {
    loadReferenceData()
      .then((ref) => {
        setCategories(ref.categories);
        setLocations(ref.locations);
      })
      .catch((e) => setError(friendlyError(e)));
    loadPlaces().then(setPlaces).catch(() => undefined);
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
        const rows = await fetchListings(debouncedTerm, filters, nextPage, null, province);
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
    [debouncedTerm, filters, province],
  );

  useEffect(() => {
    load(0, true);
  }, [load]);

  // Rails refresh every time the tab comes back into view, so "recently viewed" is current.
  const loadRails = useCallback(async () => {
    const [promoted, featured, trending, recommended, recent] = await Promise.all([
      safely(fetchPromoted()),
      safely(fetchFeatured()),
      safely(fetchTrending()),
      signedIn ? safely(fetchRecommended()) : Promise.resolve([]),
      signedIn ? safely(fetchRecentlyViewed()) : Promise.resolve([]),
    ]);
    setRails({ promoted, featured, trending, recommended, recent });
  }, [signedIn]);

  useFocusEffect(
    useCallback(() => {
      void loadRails();
    }, [loadRails]),
  );

  // The delivery location is re-read each time Home comes back into view, so a change made elsewhere shows at once.
  useFocusEffect(
    useCallback(() => {
      if (!signedIn) {
        setMyAddress(null);
        return;
      }
      listMyAddresses().then((rows) => setMyAddress(pickDeliveryAddress(rows))).catch(() => undefined);
    }, [signedIn]),
  );

  // An area chosen earlier is dropped if the person's province changed.
  useEffect(() => {
    if (places.length === 0 || filters.locationId === null) return;
    if (validArea(places, province, filters.locationId) === null) setFilters((f) => ({ ...f, locationId: null }));
  }, [places, province, filters.locationId]);

  function editDeliveryLocation() {
    if (!signedIn) {
      router.push('/sign-in');
      return;
    }
    router.push(myAddress ? { pathname: '/addresses/edit', params: { id: myAddress.id } } : { pathname: '/addresses/edit', params: { preset: 'delivery' } });
  }

  async function clearHistory() {
    try {
      await clearRecentlyViewed();
      setRails((r) => ({ ...r, recent: [] }));
    } catch (e) {
      showAlert('Could not clear your history', friendlyError(e));
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
      showAlert('Search saved', 'You will see new matching items under Alerts in your account.');
    } catch (e) {
      showAlert('Could not save this search', friendlyError(e));
    }
  }

  const areaName = browseLabel(places, province, filters.locationId);

  const header = (
    <View>
      {searching && canSaveSearch ? (
        <Pressable accessibilityRole="button" onPress={onSaveSearch} style={styles.saveRow}>
          <Text style={styles.saveText}>Alert me about new matches</Text>
        </Pressable>
      ) : null}

      {!searching ? (
        <View style={{ paddingTop: spacing.sm }}>
 <ListingRail title="Promoted" note="Paid promotion by sellers" items={rails.promoted} />
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

          <Text style={styles.allTitle}>{filters.locationId === null ? `New in ${province}` : `New in ${areaName}`}</Text>
        </View>
      ) : null}
    </View>
  );

  return (
    <View style={styles.screen}>
      <AnnouncementBanner signedIn={signedIn} />
      {signedIn ? <DeliveryBar line={deliveryShort(places, myAddress)} onPress={editDeliveryLocation} /> : null}
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

      <View style={styles.nearRow}>
        <Pressable accessibilityRole="button" accessibilityLabel={filters.locationId === null ? 'Search for items near you' : `Showing ${areaName}. Change area`} onPress={() => setAreaOpen(true)} style={[styles.nearButton, filters.locationId !== null && styles.nearOn]}>
          <Ionicons name="navigate-outline" size={18} color={colors.primary} accessibilityElementsHidden />
          <Text style={styles.nearText} numberOfLines={1}>{filters.locationId === null ? 'Search for items near you' : `Near you: ${areaName}`}</Text>
        </Pressable>
        {filters.locationId !== null ? (
          <Pressable accessibilityRole="button" accessibilityLabel={`Show all of ${province}`} onPress={() => setFilters((f) => ({ ...f, locationId: null }))} hitSlop={8}>
            <Text style={styles.link}>All of {province}</Text>
          </Pressable>
        ) : null}
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

      <AreaSheet
        visible={areaOpen}
        places={places}
        province={province}
        selectedId={filters.locationId}
        onPick={(id) => {
          setFilters((f) => ({ ...f, locationId: id }));
          setAreaOpen(false);
        }}
        onClose={() => setAreaOpen(false)}
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
  nearRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md, paddingHorizontal: spacing.lg, paddingBottom: spacing.sm },
  nearButton: { flex: 1, flexDirection: 'row', alignItems: 'center', gap: spacing.sm, minHeight: 44, paddingHorizontal: spacing.md, borderRadius: radius.md, borderWidth: 1, borderColor: colors.primary, backgroundColor: colors.surface },
  nearOn: { backgroundColor: colors.primarySoft },
  nearText: { flex: 1, fontSize: 15, fontWeight: '600', color: colors.primary },
  allTitle: { fontSize: 18, fontWeight: '700', color: colors.text, paddingHorizontal: spacing.lg, marginBottom: spacing.sm },
  empty: { alignItems: 'center', padding: spacing.xl, gap: spacing.xs },
  emptyTitle: { fontSize: 18, fontWeight: '600', color: colors.text },
  emptyText: { color: colors.muted },
});
