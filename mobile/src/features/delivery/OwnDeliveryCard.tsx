import { useCallback, useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice } from '../../components/ui';
import { canEnterPin, cleanPin, isLive, nextStep, ownDeliveryLabel, pinReady, pinResultMessage, type DeliveryView } from '../../domain/ownDelivery';
import { friendlyError } from '../../lib/errors';
import { showAlert } from '../../lib/dialog';
import { colors, radius, spacing } from '../../theme';
import { cancelDelivery, confirmDropoff, fetchDeliveryView, setDeliveryStep, startDelivery } from './api';

type Props = { orderId: string; role: 'buyer' | 'seller'; canStart: boolean; onChanged: () => void };

// Delivery by the seller's own rider. There is no map: the buyer sees the steps and a PIN, and gives the PIN to the rider at hand-over.
export function OwnDeliveryCard({ orderId, role, canStart, onChanged }: Props) {
  const [view, setView] = useState<DeliveryView | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [pickup, setPickup] = useState('');
  const [rider, setRider] = useState('');
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');

  const load = useCallback(async () => {
    try {
      setView(await fetchDeliveryView(orderId));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoaded(true);
    }
  }, [orderId]);

  useEffect(() => { load(); }, [load]);

  async function run(work: () => Promise<void>) {
    setBusy(true);
    setError('');
    try {
      await work();
      await load();
      onChanged();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!loaded) return null;
  const live = view ? isLive(view.status) : false;
  if (!view && !(role === 'seller' && canStart)) return null;

  return (
    <View style={styles.card}>
      <Text style={styles.title}>Delivery</Text>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {message ? <Notice tone="info">{message}</Notice> : null}

      {!view && role === 'seller' ? (
        <>
          <Text style={styles.meta}>Use your own rider. The buyer gets a PIN and gives it to the rider when the item arrives. There is no map or live tracking.</Text>
          <Field label="Where will the item be picked up?" value={pickup} onChangeText={setPickup} maxLength={300} />
          <Field label="Rider's name (optional)" value={rider} onChangeText={setRider} maxLength={60} />
          <Button title="Start delivery" onPress={() => run(() => startDelivery(orderId, pickup, rider))} loading={busy} disabled={busy || pickup.trim().length === 0} />
        </>
      ) : null}

      {view ? (
        <>
          <Text style={styles.status}>{ownDeliveryLabel(view.status)}</Text>
          {view.riderName ? <Text style={styles.meta}>Rider: {view.riderName}</Text> : null}
          <Text style={styles.meta}>From: {view.pickupAddress}</Text>
          <Text style={styles.meta}>To: {view.destinationAddress}</Text>
          {view.statusReason ? <Text style={styles.meta}>Reason: {view.statusReason}</Text> : null}

          {role === 'buyer' && view.pin ? (
            <View style={styles.pinBox}>
              <Text style={styles.pinLabel}>Your delivery PIN</Text>
              <Text style={styles.pin}>{view.pin}</Text>
              <Text style={styles.meta}>Give this PIN to the rider only when you are holding the item. Never send it by message beforehand.</Text>
            </View>
          ) : null}

          {role === 'seller' && live ? (
            <>
              {nextStep(view.status) ? (
                <Button title={nextStep(view.status)!.button} onPress={() => run(() => setDeliveryStep(view.id, nextStep(view.status)!.to))} loading={busy} disabled={busy} />
              ) : null}
              {canEnterPin(view.status, view.attemptsLeft) ? (
                <>
                  <Field label="PIN from the buyer" value={pin} onChangeText={(t) => setPin(cleanPin(t))} keyboardType="number-pad" maxLength={4} />
                  <Button
                    title="Confirm hand-over"
                    disabled={busy || !pinReady(pin)}
                    loading={busy}
                    onPress={async () => {
                      setBusy(true);
                      setError('');
                      try {
                        const r = await confirmDropoff(view.id, pin);
                        setMessage(pinResultMessage(r.ok, r.attemptsLeft));
                        setPin('');
                        await load();
                        if (r.ok) onChanged();
                      } catch (e) {
                        setError(friendlyError(e));
                      } finally {
                        setBusy(false);
                      }
                    }}
                  />
                </>
              ) : view.attemptsLeft <= 0 ? (
                <Notice tone="error">{pinResultMessage(false, 0)}</Notice>
              ) : null}
              <Button
                title="Cancel this delivery"
                variant="secondary"
                disabled={busy}
                onPress={() =>
                  showAlert('Cancel this delivery?', 'The buyer will be told. You can start a new delivery afterwards.', [
                    { text: 'Keep it', style: 'cancel' },
                    { text: 'Cancel delivery', style: 'destructive', onPress: () => run(() => cancelDelivery(view.id, 'Cancelled by the seller')) },
                  ])
                }
              />
            </>
          ) : null}

          {view.events.length > 0 ? (
            <View style={{ gap: 2 }}>
              {view.events.map((e, i) => (
                <Text key={i} style={styles.meta}>
                  {new Date(e.at).toLocaleString('en-ZM')}: {e.note ?? ownDeliveryLabel(e.status)}
                </Text>
              ))}
            </View>
          ) : null}
        </>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  status: { fontSize: 15, fontWeight: '600', color: colors.primary },
  meta: { fontSize: 13, color: colors.muted },
  pinBox: { alignItems: 'center', gap: spacing.xs, padding: spacing.md, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border },
  pinLabel: { fontSize: 13, color: colors.muted },
  pin: { fontSize: 36, fontWeight: '800', letterSpacing: 8, color: colors.text },
});
