import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Field, Notice, SectionTitle } from '../../../../src/components/ui';
import {
  createCatalogue,
  deleteCatalogue,
  fetchBusinessListings,
  fetchCatalogueListingIds,
  fetchCatalogues,
  saveCatalogue,
  setCatalogueListings,
  type BusinessListing,
  type Catalogue,
} from '../../../../src/features/business/api';
import { friendlyError } from '../../../../src/lib/errors';
import { colors, radius, spacing } from '../../../../src/theme';

export default function Catalogues() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [items, setItems] = useState<Catalogue[]>([]);
  const [listings, setListings] = useState<BusinessListing[]>([]);
  const [name, setName] = useState('');
  const [editing, setEditing] = useState<string | null>(null);
  const [chosen, setChosen] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const [c, l] = await Promise.all([fetchCatalogues(id), fetchBusinessListings(id)]);
      setItems(c);
      setListings(l);
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [id]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  async function run(action: () => Promise<unknown>) {
    setBusy(true);
    setError('');
    try {
      await action();
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  async function startEditing(c: Catalogue) {
    if (editing === c.id) return setEditing(null);
    try {
      setChosen(await fetchCatalogueListingIds(c.id));
      setEditing(c.id);
    } catch (e) {
      setError(friendlyError(e));
    }
  }

  const toggle = (listingId: string) => setChosen((cur) => (cur.includes(listingId) ? cur.filter((x) => x !== listingId) : [...cur, listingId]));

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Notice>Catalogues group your listings on your public page, for example "Phones" or "Chargers". A hidden catalogue is not shown to visitors.</Notice>
      {items.map((c) => (
        <View key={c.id} style={styles.card}>
          <Text style={styles.name}>{c.name}{c.visible ? '' : ' (hidden)'}</Text>
          <Button title={editing === c.id ? 'Close' : 'Choose listings'} variant="secondary" onPress={() => startEditing(c)} />
          {editing === c.id ? (
            <>
              <View style={styles.chips}>
                {listings.map((l) => (
                  <Chip key={l.id} label={l.title} selected={chosen.includes(l.id)} onPress={() => toggle(l.id)} />
                ))}
              </View>
              {listings.length === 0 ? <Text style={styles.meta}>Post a business listing first.</Text> : null}
              <Button title="Save listings" disabled={busy} onPress={() => run(() => setCatalogueListings(c.id, chosen))} />
            </>
          ) : null}
          <Button title={c.visible ? 'Hide from visitors' : 'Show to visitors'} variant="secondary" disabled={busy} onPress={() => run(() => saveCatalogue(c, { visible: !c.visible }))} />
          <Button title="Delete catalogue" variant="danger" disabled={busy} onPress={() => run(() => deleteCatalogue(c.id))} />
        </View>
      ))}
      <SectionTitle>New catalogue</SectionTitle>
      <Field label="Name" value={name} onChangeText={setName} maxLength={60} />
      <Button
        title="Create"
        loading={busy}
        onPress={() => {
          if (name.trim().length < 2) return setError('Give the catalogue a name.');
          run(async () => {
            await createCatalogue(id!, name, '');
            setName('');
          });
        }}
      />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  name: { fontSize: 16, fontWeight: '600', color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
});
