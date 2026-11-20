import { useEffect, useState } from 'react';
import { Modal, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { CONDITIONS, type ItemCondition } from '../domain/listing';
import { defaultFilters, type Category, type Filters, type Location, type SortOrder } from '../features/listings/types';
import { colors, spacing } from '../theme';
import { Button, Chip, Field, SectionTitle } from './ui';

type Props = {
  visible: boolean;
  filters: Filters;
  categories: Category[];
  locations: Location[];
  onApply: (filters: Filters) => void;
  onClose: () => void;
};

const SORTS: { value: SortOrder; label: string }[] = [
  { value: 'newest', label: 'Newest' },
  { value: 'price_asc', label: 'Price: low to high' },
  { value: 'price_desc', label: 'Price: high to low' },
];

export function FilterSheet({ visible, filters, categories, locations, onApply, onClose }: Props) {
  const [draft, setDraft] = useState<Filters>(filters);

  useEffect(() => {
    if (visible) setDraft(filters);
  }, [visible, filters]);

  function toggleCondition(value: ItemCondition) {
    setDraft((d) => ({
      ...d,
      conditions: d.conditions.includes(value) ? d.conditions.filter((c) => c !== value) : [...d.conditions, value],
    }));
  }

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView style={styles.screen}>
        <ScrollView contentContainerStyle={styles.content}>
          <Text style={styles.heading}>Filters</Text>

          <SectionTitle>Category</SectionTitle>
          <View style={styles.row}>
            <Chip label="All" selected={draft.categoryId === null} onPress={() => setDraft({ ...draft, categoryId: null })} />
            {categories.map((c) => (
              <Chip key={c.id} label={c.name} selected={draft.categoryId === c.id} onPress={() => setDraft({ ...draft, categoryId: c.id })} />
            ))}
          </View>

          <SectionTitle>Area</SectionTitle>
          <View style={styles.row}>
            <Chip label="Anywhere" selected={draft.locationId === null} onPress={() => setDraft({ ...draft, locationId: null })} />
            {locations
              .filter((l) => l.area)
              .map((l) => (
                <Chip key={l.id} label={l.area ?? ''} selected={draft.locationId === l.id} onPress={() => setDraft({ ...draft, locationId: l.id })} />
              ))}
          </View>

          <SectionTitle>Condition</SectionTitle>
          <View style={styles.row}>
            {CONDITIONS.map((c) => (
              <Chip key={c.value} label={c.label} selected={draft.conditions.includes(c.value)} onPress={() => toggleCondition(c.value)} />
            ))}
          </View>

          <SectionTitle>Price (kwacha)</SectionTitle>
          <View style={styles.row}>
            <View style={{ flex: 1 }}>
              <Field label="From" value={draft.minPrice} onChangeText={(v) => setDraft({ ...draft, minPrice: v })} keyboardType="numeric" />
            </View>
            <View style={{ flex: 1 }}>
              <Field label="To" value={draft.maxPrice} onChangeText={(v) => setDraft({ ...draft, maxPrice: v })} keyboardType="numeric" />
            </View>
          </View>

          <View style={styles.switchRow}>
            <Text style={styles.switchLabel}>Verified sellers only</Text>
            <Switch
              value={draft.verifiedOnly}
              onValueChange={(v) => setDraft({ ...draft, verifiedOnly: v })}
              trackColor={{ true: colors.primary, false: colors.border }}
            />
          </View>

          <SectionTitle>Sort by</SectionTitle>
          <View style={styles.row}>
            {SORTS.map((s) => (
              <Chip key={s.value} label={s.label} selected={draft.sort === s.value} onPress={() => setDraft({ ...draft, sort: s.value })} />
            ))}
          </View>
        </ScrollView>

        <View style={styles.footer}>
          <View style={{ flex: 1 }}>
            <Button title="Clear" variant="secondary" onPress={() => setDraft(defaultFilters)} />
          </View>
          <View style={{ flex: 2 }}>
            <Button title="Show results" onPress={() => onApply(draft)} />
          </View>
        </View>
      </SafeAreaView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  heading: { fontSize: 24, fontWeight: '700', color: colors.text },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  switchRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingVertical: spacing.sm },
  switchLabel: { fontSize: 16, color: colors.text },
  footer: {
    flexDirection: 'row',
    gap: spacing.md,
    padding: spacing.lg,
    borderTopWidth: 1,
    borderTopColor: colors.border,
    backgroundColor: colors.surface,
  },
});
