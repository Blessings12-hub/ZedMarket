import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice, SectionTitle } from '../../../src/components/ui';
import { formatKwacha } from '../../../src/domain/money';
import { movePhoto, parseWhole, sellerState } from '../../../src/domain/sellerTools';
import { fetchListingPerformance } from '../../../src/features/analytics/api';
import {
  duplicateListing, fetchPhotos, fetchTimeline, fetchTracker, reorderPhotos, type Photo, type TimelineEntry, type TrackedListing,
} from '../../../src/features/seller/api';
import { friendlyError } from '../../../src/lib/errors';
import { listingImageUrl } from '../../../src/lib/supabase';
import { colors, radius, spacing } from '../../../src/theme';

export default function SellerListing() {
  const router = useRouter();
  const { id, business } = useLocalSearchParams<{ id: string; business?: string }>();
  const biz = business ? String(business) : null;
  const [item, setItem] = useState<TrackedListing | null>(null);
  const [timeline, setTimeline] = useState<TimelineEntry[]>([]);
  const [photos, setPhotos] = useState<Photo[]>([]);
  const [perf, setPerf] = useState<any>(null);
  const [sku, setSku] = useState('');
  const [qty, setQty] = useState('');
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const all = await fetchTracker(biz, 'all', '');
      setItem(all.find((l) => l.id === id) ?? null);
      setTimeline(await fetchTimeline(String(id)));
      setPhotos(await fetchPhotos(String(id)));
      // Performance needs the analytics permission (the owner or a manager for a business). Others simply do not see it.
      setPerf(await fetchListingPerformance(String(id), 30).catch(() => null));
      setError('');
    } catch (e) { setError(friendlyError(e)); }
  }, [id, biz]);
  useFocusEffect(useCallback(() => { load(); }, [load]));

  async function copy() {
    setBusy(true); setError(''); setNote('');
    try {
      const withStock = biz && sku.trim() !== '';
      const q = parseWhole(qty);
      if (withStock && q === null) throw new Error('Enter the quantity as a whole number.');
      const newId = await duplicateListing(String(id), undefined, withStock ? sku.trim() : undefined, withStock ? (q as number) : undefined);
      setNote('A draft copy was made. Add photos and publish it when it is ready.');
      router.replace({ pathname: '/selling/listing/[id]', params: { id: newId, business: biz ?? '' } });
    } catch (e) { setError(friendlyError(e)); } finally { setBusy(false); }
  }

  async function move(i: number, d: -1 | 1) {
    const next = movePhoto(photos, i, d);
    if (next === photos) return;
    setPhotos(next);
    try { await reorderPhotos(String(id), next.map((p) => p.id)); } catch (e) { setError(friendlyError(e)); load(); }
  }

  if (!item) return <View style={styles.screen}>{error ? <Notice tone="error">{error}</Notice> : <Text style={styles.text}>Loading…</Text>}</View>;
  const st = sellerState(item.status, item.moderation);

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {note ? <Notice>{note}</Notice> : null}
      <Text style={styles.title}>{item.title}</Text>
      <Text style={styles.text}>{`${formatKwacha(item.price)} · ${st.label}${item.tracked ? ` · ${item.quantity} in stock` : ''}`}</Text>
      <Notice tone={st.tone === 'bad' ? 'error' : st.tone === 'wait' ? 'warning' : 'info'}>{st.next}</Notice>
      {item.moderation === 'rejected' && item.note ? <Text style={styles.err}>{`Reason: ${item.note}`}</Text> : null}
      {item.moderation === 'rejected' ? <Button title="Appeal this decision" variant="secondary" onPress={() => router.push({ pathname: '/appeal', params: { targetType: 'listing', targetId: item.id } })} /> : null}
      <Button title="View listing" variant="secondary" onPress={() => router.push(`/listing/${item.id}`)} />

      <SectionTitle>Status history</SectionTitle>
      {timeline.map((t, i) => {
        const s = sellerState(t.status, t.moderation);
        return (
          <View key={i} style={styles.row}>
            <Text style={styles.name}>{s.label}</Text>
            <Text style={styles.small}>{`${t.at.slice(0, 16).replace('T', ' ')}${t.byStaff ? ' · by our team' : ''}`}</Text>
            {t.note ? <Text style={styles.text}>{t.note}</Text> : null}
          </View>
        );
      })}

      <SectionTitle>Last 30 days</SectionTitle>
      {perf ? (
        <Text style={styles.text}>{`${perf.views} views by ${perf.unique_viewers} people · ${perf.saves_total} saves · ${perf.chats_started} chats · ${perf.orders_requested} orders requested · ${perf.orders_completed} completed`}</Text>
      ) : <Text style={styles.small}>Detailed numbers are shown to the owner or a manager.</Text>}

      <SectionTitle>Photos</SectionTitle>
      <Text style={styles.small}>The first photo is the cover. Up to 10 photos.</Text>
      {photos.length === 0 ? <Text style={styles.text}>No photos yet.</Text> : null}
      {photos.map((p, i) => (
        <View key={p.id} style={styles.photoRow}>
          <Image source={{ uri: listingImageUrl(p.path) }} style={styles.photo} />
          <View style={{ flex: 1, gap: spacing.xs }}>
            <Text style={styles.name}>{i === 0 ? 'Cover photo' : `Photo ${i + 1}`}</Text>
            <View style={styles.chips}>
              <Button title="Earlier" variant="secondary" onPress={() => move(i, -1)} disabled={i === 0} />
              <Button title="Later" variant="secondary" onPress={() => move(i, 1)} disabled={i === photos.length - 1} />
            </View>
          </View>
        </View>
      ))}

      <SectionTitle>Make a copy</SectionTitle>
      <Text style={styles.small}>The copy is a draft with the same details. Photos are not copied.</Text>
      {biz ? (
        <>
          <Field label="SKU for the copy (optional, to track its stock)" value={sku} onChangeText={setSku} autoCapitalize="none" />
          {sku.trim() !== '' ? <Field label="Quantity" value={qty} onChangeText={setQty} keyboardType="number-pad" /> : null}
        </>
      ) : null}
      <Button title="Duplicate this listing" onPress={copy} loading={busy} />
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
  name: { fontSize: 15, fontWeight: '700', color: colors.text },
  chips: { flexDirection: 'row', gap: spacing.sm },
  row: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 2 },
  photoRow: { flexDirection: 'row', gap: spacing.md, alignItems: 'center', backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.sm },
  photo: { width: 84, height: 84, borderRadius: radius.sm ?? 8, backgroundColor: colors.primarySoft },
});
