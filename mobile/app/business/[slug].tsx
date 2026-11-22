import { useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, FlatList, Share, StyleSheet, Text, View } from 'react-native';

import { ListingCard } from '../../src/components/ListingCard';
import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import {
  STOREFRONT_PAGE,
  fetchStorefront,
  fetchStorefrontBranches,
  fetchStorefrontCatalogues,
  fetchStorefrontListings,
  type Storefront,
  type StorefrontBranch,
  type StorefrontCatalogue,
  type StorefrontListing,
} from '../../src/features/business/api';
import type { ListingSummary } from '../../src/features/listings/types';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

// A business's public page. Anyone can open it, including people who are not signed in.
export default function BusinessStorefront() {
  const { slug } = useLocalSearchParams<{ slug: string }>();
  const [shop, setShop] = useState<Storefront | null>(null);
  const [branches, setBranches] = useState<StorefrontBranch[]>([]);
  const [catalogues, setCatalogues] = useState<StorefrontCatalogue[]>([]);
  const [catalogue, setCatalogue] = useState<string | null>(null);
  const [term, setTerm] = useState('');
  const [items, setItems] = useState<StorefrontListing[]>([]);
  const [finished, setFinished] = useState(false);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [missing, setMissing] = useState(false);

  useEffect(() => {
    if (!slug) return;
    let cancelled = false;
    (async () => {
      try {
        const s = await fetchStorefront(String(slug).toLowerCase());
        if (cancelled) return;
        if (!s) {
          setMissing(true);
          return;
        }
        setShop(s);
        const [b, c] = await Promise.all([fetchStorefrontBranches(s.id), fetchStorefrontCatalogues(s.id)]);
        if (cancelled) return;
        setBranches(b);
        setCatalogues(c);
      } catch (e) {
        if (!cancelled) setError(friendlyError(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [slug]);

  const load = useCallback(
    async (offset = 0) => {
      if (!shop) return;
      try {
        const page = await fetchStorefrontListings(shop.id, catalogue, term, offset);
        setItems((current) => (offset === 0 ? page : [...current, ...page]));
        setFinished(page.length < STOREFRONT_PAGE);
        setError('');
      } catch (e) {
        setError(friendlyError(e));
      }
    },
    [shop, catalogue, term],
  );

  useEffect(() => {
    load(0);
  }, [load]);

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator color={colors.primary} />
      </View>
    );
  }
  if (missing || !shop) {
    return (
      <View style={styles.center}>
        <Notice tone={error ? 'error' : 'info'}>{error || 'This shop page is not available.'}</Notice>
      </View>
    );
  }

  const cards: ListingSummary[] = items.map((i) => ({
    id: i.id,
    title: i.title,
    price: i.price,
    condition: i.condition as ListingSummary['condition'],
    area: i.area ?? '',
    imagePath: i.imagePath,
    sellerName: shop.name,
    sellerLevel: shop.verified ? 'identity_verified' : 'unverified',
  }));

  const header = (
    <View style={styles.head}>
      <View style={styles.card}>
        <Text style={styles.name}>{shop.name}</Text>
        {shop.verified ? <Text style={styles.verified}>Registration checked by ZedMarket staff</Text> : <Text style={styles.meta}>Registration not checked yet</Text>}
        {shop.description ? <Text style={styles.text}>{shop.description}</Text> : null}
        <Text style={styles.meta}>{[shop.area, shop.town].filter(Boolean).join(', ') || 'Zambia'}</Text>
        {shop.address ? <Text style={styles.meta}>{shop.address}</Text> : null}
        <Button
          title="Share this shop"
          variant="secondary"
          onPress={() => Share.share({ message: `${shop.name} on ZedMarket` }).catch(() => {})}
        />
      </View>

      {branches.length > 0 ? (
        <>
          <SectionTitle>Branches</SectionTitle>
          {branches.map((b) => (
            <View key={b.id} style={styles.card}>
              <Text style={styles.text}>{b.name}{b.isMain ? ' (main)' : ''}</Text>
              <Text style={styles.meta}>{[b.address, b.area].filter(Boolean).join(', ')}</Text>
              {b.phone ? <Text selectable style={styles.meta}>{b.phone}</Text> : null}
            </View>
          ))}
        </>
      ) : null}

      <SectionTitle>{`For sale (${shop.listingCount})`}</SectionTitle>
      {catalogues.length > 0 ? (
        <View style={styles.chips}>
          <Chip label="Everything" selected={catalogue === null} onPress={() => setCatalogue(null)} />
          {catalogues.map((c) => (
            <Chip key={c.id} label={`${c.name} (${c.listingCount})`} selected={catalogue === c.id} onPress={() => setCatalogue(c.id)} />
          ))}
        </View>
      ) : null}
      <Field label="Search this shop" value={term} onChangeText={setTerm} returnKeyType="search" />
      {error ? <Notice tone="error">{error}</Notice> : null}
      {items.length === 0 ? <Text style={styles.meta}>Nothing for sale here right now.</Text> : null}
    </View>
  );

  return (
    <FlatList
      style={styles.screen}
      data={cards}
      keyExtractor={(i) => i.id}
      numColumns={2}
      columnWrapperStyle={{ gap: spacing.md, paddingHorizontal: spacing.lg }}
      contentContainerStyle={{ gap: spacing.md, paddingBottom: spacing.xl }}
      ListHeaderComponent={header}
      renderItem={({ item }) => <ListingCard listing={item} />}
      onEndReached={() => {
        if (!finished) load(items.length);
      }}
      onEndReachedThreshold={0.4}
    />
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl, backgroundColor: colors.background },
  head: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  name: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
  verified: { fontSize: 13, color: colors.primary, fontWeight: '600' },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
});
