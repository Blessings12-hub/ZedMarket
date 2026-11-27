import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice } from '../../../../src/components/ui';
import { fetchBranches, type Branch } from '../../../../src/features/business/api';
import { fetchBranchStock, setBranchStock, type BranchStockRow } from '../../../../src/features/orders/api';
import { friendlyError } from '../../../../src/lib/errors';
import { singleFlight } from '../../../../src/lib/singleFlight';
import { colors, radius, spacing } from '../../../../src/theme';

// Stock per branch for one listing. Once a listing keeps stock per branch its total is the sum of the branches.
export default function BranchStock() {
  const { id, listingId } = useLocalSearchParams<{ id: string; listingId: string }>();
  const [branches, setBranches] = useState<Branch[] | null>(null);
  const [rows, setRows] = useState<BranchStockRow[]>([]);
  const [text, setText] = useState<Record<string, string>>({});
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  const busy = useRef(false);

  const load = useMemo(() => singleFlight(async () => {
    try {
      const [b, r] = await Promise.all([fetchBranches(id), fetchBranchStock(listingId)]);
      setBranches(b.filter((x) => x.active));
      setRows(r);
      setText(Object.fromEntries(r.map((x) => [x.id, String(x.quantity)])));
      setError('');
    } catch (e) {
      console.error('[stock] branch stock failed to load', e);
      setError(friendlyError(e));
      setBranches((cur) => cur ?? []);
    }
  }), [id, listingId]);
  useFocusEffect(useCallback(() => { void load(); }, [load]));

  async function save(branchId: string) {
    if (busy.current) return;
    const t = (text[branchId] ?? '').trim();
    if (!/^\d{1,6}$/.test(t)) {
      setError('Enter the quantity as a whole number.');
      return;
    }
    busy.current = true;
    setError('');
    setMessage('');
    try {
      await setBranchStock(listingId, branchId, Number(t), '');
      setMessage('Saved.');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      busy.current = false;
    }
  }

  if (!branches) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {error ? <Button title="Try again" variant="secondary" onPress={() => void load()} /> : null}
      {message ? <Notice>{message}</Notice> : null}
      <Notice>The first time you set a branch, the stock this listing already has moves into its own branch, so nothing is lost. After that, change stock here, per branch.</Notice>
      {branches.length === 0 && !error ? <Text style={styles.text}>Add a branch first.</Text> : null}
      {branches.map((b) => {
        const row = rows.find((r) => r.id === b.id);
        return (
          <View key={b.id} style={styles.card}>
            <Text style={styles.title}>{b.name}{b.isMain ? ' (main)' : ''}</Text>
            {row ? <Text style={styles.text}>{row.reserved} reserved for confirmed orders · {row.available} free</Text> : <Text style={styles.text}>Holds none yet</Text>}
            <Field label="Quantity in this branch" value={text[b.id] ?? '0'} onChangeText={(v) => setText((t) => ({ ...t, [b.id]: v.replace(/[^0-9]/g, '') }))} keyboardType="number-pad" />
            <Button title="Save" onPress={() => save(b.id)} />
          </View>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl * 2 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  text: { fontSize: 13, color: colors.muted },
});
