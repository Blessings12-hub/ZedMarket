import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Field, Notice } from '../../src/components/ui';
import { fetchFlags, resolveFlag, type PhotoFlag } from '../../src/features/comparison/flags';
import { friendlyError } from '../../src/lib/errors';
import { singleFlight } from '../../src/lib/singleFlight';
import { colors, radius, spacing } from '../../src/theme';

// Photos that are byte-for-byte the same on two different sellers' listings. Nothing is removed automatically.
export default function PhotoFlags() {
  const router = useRouter();
  const [status, setStatus] = useState<'open' | 'confirmed' | 'dismissed'>('open');
  const [rows, setRows] = useState<PhotoFlag[] | null>(null);
  const [note, setNote] = useState('');
  const [error, setError] = useState('');
  const busy = useRef(false);

  const load = useMemo(() => singleFlight(async (s: typeof status) => {
    setRows(null);
    try { setRows(await fetchFlags(s)); setError(''); } catch (e) { setError(friendlyError(e)); setRows([]); }
  }), []);
  useFocusEffect(useCallback(() => { void load(status); }, [load, status]));

  const decide = async (id: string, d: 'dismiss' | 'confirm') => {
    if (busy.current) return;
    busy.current = true;
    try { await resolveFlag(id, d, note); setNote(''); setError(''); await load(status); } catch (e) { setError(friendlyError(e)); } finally { busy.current = false; }
  };

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <View style={styles.chips}>{(['open', 'confirmed', 'dismissed'] as const).map((s) => <Chip key={s} label={s} selected={status === s} onPress={() => setStatus(s)} />)}</View>
      <Notice>Only identical files are caught. Stock photos and honest re-use exist, so look before you decide.</Notice>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {rows === null ? <ActivityIndicator color={colors.primary} /> : null}
      {rows?.length === 0 && !error ? <Text style={styles.text}>Nothing here.</Text> : null}
      {status === 'open' && rows && rows.length > 0 ? <Field label="Note (optional)" value={note} onChangeText={setNote} /> : null}
      {rows?.map((r) => (
        <View key={r.id} style={styles.card}>
          <Text style={styles.title}>{r.title} · {r.seller}</Text>
          <Text style={styles.text}>shares a photo with: {r.otherTitle} · {r.otherSeller}</Text>
          {r.note ? <Text style={styles.text}>Note: {r.note}</Text> : null}
          <View style={styles.chips}>
            <Button title="Open first" variant="secondary" onPress={() => router.push(`/listing/${r.listingId}`)} />
            <Button title="Open second" variant="secondary" onPress={() => router.push(`/listing/${r.otherListingId}`)} />
          </View>
          {status === 'open' ? (
            <View style={styles.chips}>
              <Button title="Fine (dismiss)" variant="secondary" onPress={() => decide(r.id, 'dismiss')} />
              <Button title="Confirm a problem" variant="danger" onPress={() => decide(r.id, 'confirm')} />
            </View>
          ) : null}
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  title: { fontSize: 15, fontWeight: '700', color: colors.text },
  text: { fontSize: 13, color: colors.muted },
});
