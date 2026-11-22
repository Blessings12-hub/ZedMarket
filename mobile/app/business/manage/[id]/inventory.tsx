import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Field, Notice } from '../../../../src/components/ui';
import { STOCK_REASONS, parseQuantity, stockChange, stockLabel } from '../../../../src/domain/business';
import {
  adjustStock,
  fetchInventory,
  fetchStockHistory,
  trackStock,
  type InventoryFilter,
  type InventoryRow,
  type StockMove,
} from '../../../../src/features/business/api';
import { friendlyError } from '../../../../src/lib/errors';
import { colors, radius, spacing } from '../../../../src/theme';

const FILTERS: Array<{ label: string; value: InventoryFilter }> = [
  { label: 'All', value: 'all' },
  { label: 'Low', value: 'low' },
  { label: 'Out', value: 'out' },
  { label: 'Not tracked', value: 'untracked' },
];

export default function Inventory() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [filter, setFilter] = useState<InventoryFilter>('all');
  const [rows, setRows] = useState<InventoryRow[]>([]);
  const [open, setOpen] = useState<string | null>(null);
  const [reason, setReason] = useState<(typeof STOCK_REASONS)[number]['value']>('restock');
  const [amount, setAmount] = useState('');
  const [note, setNote] = useState('');
  const [history, setHistory] = useState<StockMove[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      setRows(await fetchInventory(id, filter));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoading(false);
    }
  }, [id, filter]);

  useFocusEffect(
    useCallback(() => {
      setLoading(true);
      load();
    }, [load]),
  );

  async function expand(row: InventoryRow) {
    setOpen(open === row.listingId ? null : row.listingId);
    setAmount('');
    setNote('');
    setError('');
    if (row.tracked) fetchStockHistory(row.listingId).then(setHistory).catch(() => setHistory([]));
    else setHistory([]);
  }

  async function startTracking(row: InventoryRow) {
    const qty = parseQuantity(amount);
    if (qty === null || qty < 0) {
      setError('Enter how many you have now, for example 5.');
      return;
    }
    setBusy(true);
    try {
      await trackStock(row.listingId, qty, 2);
      setOpen(null);
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  async function applyChange(row: InventoryRow) {
    const result = stockChange(reason, amount);
    if ('problem' in result) {
      setError(result.problem);
      return;
    }
    setBusy(true);
    try {
      await adjustStock(row.listingId, result.change, reason, note);
      setOpen(null);
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <View style={styles.screen}>
      <View style={styles.filters}>
        {FILTERS.map((f) => (
          <Chip key={f.value} label={f.label} selected={filter === f.value} onPress={() => setFilter(f.value)} />
        ))}
      </View>
      <View style={{ paddingHorizontal: spacing.lg }}>
        <Notice>When stock reaches 0 the listing is paused. Restocking brings it back. Each completed order takes off one.</Notice>
        {error ? <Notice tone="error">{error}</Notice> : null}
      </View>
      <FlatList
        data={rows}
        keyExtractor={(r) => r.listingId}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.sm, flexGrow: 1 }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>Nothing here.</Text>}
        renderItem={({ item }) => (
          <View style={styles.card}>
            <Text style={styles.title}>{item.title}</Text>
            <Text style={[styles.text, item.isLow && { color: colors.danger }]}>{stockLabel(item.quantity, item.lowStockAt)}</Text>
            <Text style={styles.meta}>{item.status}{item.branchName ? ` · ${item.branchName}` : ''}</Text>
            <Button title={open === item.listingId ? 'Close' : item.tracked ? 'Change stock' : 'Start counting stock'} variant="secondary" onPress={() => expand(item)} />
            {open === item.listingId ? (
              item.tracked ? (
                <>
                  <View style={styles.filters}>
                    {STOCK_REASONS.map((r) => (
                      <Chip key={r.value} label={r.label} selected={reason === r.value} onPress={() => setReason(r.value)} />
                    ))}
                  </View>
                  <Field label="How many?" value={amount} onChangeText={setAmount} keyboardType="numbers-and-punctuation" />
                  <Field label="Note (optional)" value={note} onChangeText={setNote} maxLength={200} />
                  <Button title="Save" onPress={() => applyChange(item)} loading={busy} />
                  {history.map((h) => (
                    <Text key={h.id} style={styles.meta}>
                      {new Date(h.createdAt).toLocaleDateString()} · {h.change > 0 ? '+' : ''}{h.change} ({h.reason}) → {h.quantityAfter}{h.actorName ? ` · ${h.actorName}` : ''}
                    </Text>
                  ))}
                </>
              ) : (
                <>
                  <Field label="How many do you have now?" value={amount} onChangeText={setAmount} keyboardType="number-pad" />
                  <Button title="Start counting" onPress={() => startTracking(item)} loading={busy} />
                </>
              )
            ) : null}
          </View>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  filters: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm, padding: spacing.sm },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  title: { fontSize: 16, fontWeight: '600', color: colors.text },
  text: { fontSize: 14, color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
