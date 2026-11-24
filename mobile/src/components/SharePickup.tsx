import { useEffect, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { ADDRESS_KIND_LABELS } from '../domain/locations';
import { listMyAddresses, sharePickupAddress, type SavedAddress } from '../features/locations/api';
import { friendlyError } from '../lib/errors';
import { spacing } from '../theme';
import { Chip, Notice, SectionTitle } from './ui';

// Seller side of a confirmed collection order: share one of your saved pickup addresses with the buyer.
// Nothing is shared until the seller taps one.
export function SharePickup({ orderId, onDone }: { orderId: string; onDone: () => void }) {
  const [rows, setRows] = useState<SavedAddress[] | null>(null);
  const [error, setError] = useState('');

  useEffect(() => {
    listMyAddresses().then((r) => setRows(r.filter((a) => a.kind !== 'delivery'))).catch(() => setRows([]));
  }, []);

  if (!rows) return null;
  if (rows.length === 0) return <Notice>Save a pickup address under Account, Saved addresses, then share it with the buyer here.</Notice>;
  return (
    <View style={styles.box}>
      <SectionTitle>Share a pickup address with the buyer</SectionTitle>
      <View style={styles.row}>
        {rows.map((a) => (
          <Chip
            key={a.id}
            label={`${a.label} (${ADDRESS_KIND_LABELS[a.kind].split(' ')[0]})`}
            onPress={() => sharePickupAddress(orderId, a.id).then(onDone).catch((e) => setError(friendlyError(e)))}
          />
        ))}
      </View>
      {error ? <Notice tone="error">{error}</Notice> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  box: { gap: spacing.sm },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
});
