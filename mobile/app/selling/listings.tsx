import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Field, Notice } from '../../src/components/ui';
import { formatKwacha } from '../../src/domain/money';
import { FILTERS, newPrice, parseNumber, parseWhole, sellerState, toggle, type PriceMode } from '../../src/domain/sellerTools';
import { bulkPrices, bulkStock, fetchTracker, type TrackedListing } from '../../src/features/seller/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';
import { SellerGate } from '../../src/components/SellerGate';

type Panel = null | 'price' | 'stock';
const MODES: { key: PriceMode; label: string; hint: string }[] = [
  { key: 'percent', label: 'Percent', hint: 'e.g. 10 raises by 10%, -5 lowers by 5%' },
  { key: 'amount', label: 'Add or take off', hint: 'e.g. 20 adds K20, -20 takes off K20' },
  { key: 'set', label: 'Set price', hint: 'The same price for every chosen listing' },
];

// One list for people selling on their own (no business param) and for a business (?business=<id>).
function SellerListings() {
  const router = useRouter();
  const { business } = useLocalSearchParams<{ business?: string }>();
  const biz = business ? String(business) : null;
  const [filter, setFilter] = useState('all');
  const [search, setSearch] = useState('');
  const [items, setItems] = useState<TrackedListing[]>([]);
  const [picked, setPicked] = useState<string[]>([]);
  const [panel, setPanel] = useState<Panel>(null);
  const [mode, setMode] = useState<PriceMode>('percent');
  const [value, setValue] = useState('');
  const [stockMode, setStockMode] = useState<'set' | 'adjust'>('adjust');
  const [error, setError] = useState('');
  const [done, setDone] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try { setItems(await fetchTracker(biz, filter, search.trim())); setError(''); } catch (e) { setError(friendlyError(e)); }
  }, [biz, filter, search]);
  useFocusEffect(useCallback(() => { load(); }, [load]));

  const chosen = items.filter((i) => picked.includes(i.id));
  const num = parseNumber(value);
  const whole = parseWhole(value);

  async function apply() {
    setBusy(true); setError(''); setDone('');
    try {
      if (panel === 'price') {
        await bulkPrices(picked, mode, num as number);
        setDone(`Changed the price of ${picked.length} listing${picked.length === 1 ? '' : 's'}. Big changes may go back to review.`);
      } else {
        await bulkStock(picked.map((id) => ({ listing_id: id, mode: stockMode, value: whole as number })));
        setDone(`Updated stock on ${picked.length} listing${picked.length === 1 ? '' : 's'}.`);
      }
      setPanel(null); setValue(''); setPicked([]);
      await load();
    } catch (e) { setError(friendlyError(e)); } finally { setBusy(false); }
  }

  const untracked = panel === 'stock' ? chosen.filter((c) => !c.tracked).length : 0;
  const ready = panel === 'price' ? num !== null && chosen.every((c) => newPrice(c.price, mode, num) !== null)
    : panel === 'stock' ? whole !== null && untracked === 0 && chosen.every((c) => stockMode === 'set' ? whole >= 0 : (c.quantity ?? 0) + whole >= 0) : false;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {done ? <Notice>{done}</Notice> : null}
      <Text style={styles.title}>{biz ? 'Business listings' : 'My listings'}</Text>
      <Field label="Search by title or SKU" value={search} onChangeText={setSearch} onSubmitEditing={load} returnKeyType="search" autoCapitalize="none" />
      <View style={styles.chips}>{FILTERS.map((f) => <Chip key={f.key} label={f.label} selected={filter === f.key} onPress={() => { setFilter(f.key); setPicked([]); }} />)}</View>

      {picked.length > 0 ? (
        <View style={styles.bar}>
          <Text style={styles.barText}>{`${picked.length} chosen`}</Text>
          <Button title="Change prices" onPress={() => { setPanel('price'); setDone(''); }} />
          {biz ? <Button title="Change stock" variant="secondary" onPress={() => { setPanel('stock'); setDone(''); }} /> : null}
          <Button title="Clear" variant="secondary" onPress={() => { setPicked([]); setPanel(null); }} />
        </View>
      ) : <Text style={styles.small}>Tap listings to choose several. Tap "Open" to see one listing in detail.</Text>}

      {panel === 'price' ? (
        <View style={styles.card}>
          <View style={styles.chips}>{MODES.map((m) => <Chip key={m.key} label={m.label} selected={mode === m.key} onPress={() => setMode(m.key)} />)}</View>
          <Text style={styles.small}>{MODES.find((m) => m.key === mode)?.hint}</Text>
          <Field label="Value" value={value} onChangeText={setValue} keyboardType="numbers-and-punctuation" />
          {num !== null ? chosen.slice(0, 5).map((c) => <Text key={c.id} style={styles.small}>{`${c.title}: ${formatKwacha(c.price)} → ${newPrice(c.price, mode, num) === null ? 'not allowed' : formatKwacha(newPrice(c.price, mode, num) as number)}`}</Text>) : null}
          {num !== null && chosen.length > 5 ? <Text style={styles.small}>{`and ${chosen.length - 5} more`}</Text> : null}
          <Button title="Apply to all chosen" onPress={apply} loading={busy} disabled={!ready} />
          <Text style={styles.small}>All or nothing: if one listing cannot change, none do.</Text>
        </View>
      ) : null}
      {panel === 'stock' ? (
        <View style={styles.card}>
          <View style={styles.chips}>
            <Chip label="Add or take off" selected={stockMode === 'adjust'} onPress={() => setStockMode('adjust')} />
            <Chip label="Set to" selected={stockMode === 'set'} onPress={() => setStockMode('set')} />
          </View>
          <Field label={stockMode === 'adjust' ? 'Change (e.g. 5 or -2)' : 'New quantity'} value={value} onChangeText={setValue} keyboardType="numbers-and-punctuation" />
          {untracked > 0 ? <Notice tone="warning">{`${untracked} chosen listing${untracked === 1 ? ' does' : 's do'} not track stock. Remove ${untracked === 1 ? 'it' : 'them'} first.`}</Notice> : null}
          <Button title="Apply to all chosen" onPress={apply} loading={busy} disabled={!ready} />
        </View>
      ) : null}

      {items.length === 0 ? <Text style={styles.text}>Nothing here yet.</Text> : null}
      {items.map((l) => {
        const st = sellerState(l.status, l.moderation);
        const on = picked.includes(l.id);
        return (
          <Pressable key={l.id} accessibilityRole="checkbox" accessibilityState={{ checked: on }} onPress={() => setPicked((p) => toggle(p, l.id))} style={[styles.card, on && styles.cardOn]}>
            <Text style={styles.name} numberOfLines={1}>{`${on ? '☑ ' : '☐ '}${l.title}`}</Text>
            <Text style={styles.text}>{`${formatKwacha(l.price)} · ${st.label}${l.tracked ? ` · ${l.quantity} in stock` : ''}${l.sku ? ` · ${l.sku}` : ''}`}</Text>
            <Text style={styles.small}>{`${l.views30} views (30 days) · ${l.saves} saves · ${l.orders} orders · ${l.photos} photo${l.photos === 1 ? '' : 's'}`}</Text>
            {l.moderation === 'rejected' && l.note ? <Text style={styles.err}>{l.note}</Text> : null}
            <Button title="Open" variant="secondary" onPress={() => router.push({ pathname: '/selling/listing/[id]', params: { id: l.id, business: biz ?? '' } })} />
          </Pressable>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  small: { fontSize: 13, lineHeight: 18, color: colors.muted },
  err: { fontSize: 14, color: colors.danger },
  name: { fontSize: 16, fontWeight: '700', color: colors.text },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  bar: { gap: spacing.sm, padding: spacing.md, borderRadius: radius.md, backgroundColor: colors.primarySoft },
  barText: { fontSize: 15, fontWeight: '700', color: colors.primaryDark },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  cardOn: { borderColor: colors.primary, borderWidth: 2 },
});

// Selling screens open only for verified sellers (and business members). Everyone else is invited to apply.
export default function SellerListingsGated() {
  return (
    <SellerGate>
      <SellerListings />
    </SellerGate>
  );
}
