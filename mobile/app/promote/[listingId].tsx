import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Notice, SectionTitle } from '../../src/components/ui';
import { formatKwacha } from '../../src/domain/money';
import { PROMOTION_DAYS, priceFor, promotionStatusText, type MyPromotion, type PromotionDays, type PromotionPrices } from '../../src/domain/promotion';
import { cancelPromotionRequest, fetchMyPromotions, fetchPromotionPrices, requestPromotion } from '../../src/features/promotion/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

// A seller asks for a listing to be promoted. Payment is arranged with the ZedMarket team outside the app.
export default function PromoteListing() {
  const { listingId } = useLocalSearchParams<{ listingId: string }>();
  const [prices, setPrices] = useState<PromotionPrices | null>(null);
  const [mine, setMine] = useState<MyPromotion[]>([]);
  const [days, setDays] = useState<PromotionDays>(7);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [done, setDone] = useState('');

  const load = useCallback(async () => {
    try {
      const [p, m] = await Promise.all([fetchPromotionPrices(), fetchMyPromotions()]);
      setPrices(p);
      setMine(m.filter((r) => r.listingId === listingId));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoading(false);
    }
  }, [listingId]);

  useFocusEffect(useCallback(() => { void load(); }, [load]));

  async function send() {
    setBusy(true);
    setError('');
    setDone('');
    try {
      await requestPromotion(listingId, days);
      setDone('Request sent. The ZedMarket team will contact you about payment. Your listing is promoted once they approve it.');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  async function cancel(id: string) {
    try {
      await cancelPromotionRequest(id);
      await load();
    } catch (e) {
      setError(friendlyError(e));
    }
  }

  if (loading) return <ActivityIndicator style={{ marginTop: spacing.xl }} color={colors.primary} />;
  const waiting = mine.some((r) => r.status === 'requested');

  return (
    <ScrollView contentContainerStyle={styles.content} style={{ backgroundColor: colors.background }}>
      <Notice>
        Promoted listings appear in a row marked "Promoted" on the home page. This is paid advertising, so it is always labelled and does not change the reviews or the ZedMarket checks on your listing.
        You pay the ZedMarket team directly. Nothing is charged in the app.
      </Notice>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {done ? <Notice>{done}</Notice> : null}

      <SectionTitle>How long?</SectionTitle>
      {prices ? (
        PROMOTION_DAYS.map((d) => (
          <Button key={d} title={`${d} days: ${formatKwacha(priceFor(prices, d))}`} variant={days === d ? 'primary' : 'secondary'} onPress={() => setDays(d)} />
        ))
      ) : (
        <Notice tone="warning">Prices are not available right now. Try again later.</Notice>
      )}
      <Button title="Ask for promotion" onPress={send} loading={busy} disabled={busy || waiting || !prices} />
      {waiting ? <Text style={styles.meta}>You already have a request waiting for this listing.</Text> : null}

      {mine.length > 0 ? <SectionTitle>Your requests for this listing</SectionTitle> : null}
      {mine.map((r) => (
        <View key={r.id} style={styles.card}>
          <Text style={styles.line}>{r.days} days · {formatKwacha(r.price)}</Text>
          <Text style={styles.status}>{promotionStatusText(r.status)}</Text>
          {r.decisionNote ? <Text style={styles.meta}>{r.decisionNote}</Text> : null}
          {r.liveUntil ? <Text style={styles.meta}>Promoted until {new Date(r.liveUntil).toLocaleDateString('en-ZM')}</Text> : null}
          {r.status === 'requested' ? <Button title="Cancel request" variant="secondary" onPress={() => cancel(r.id)} /> : null}
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  line: { fontSize: 15, color: colors.text },
  status: { fontSize: 15, fontWeight: '600', color: colors.primary },
  meta: { fontSize: 13, color: colors.muted },
});
