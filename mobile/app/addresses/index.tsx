import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Linking, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Notice } from '../../src/components/ui';
import { ADDRESS_KIND_LABELS, formatPlace, mapsLink, type Place } from '../../src/domain/locations';
import { deleteAddress, listMyAddresses, loadPlaces, type SavedAddress } from '../../src/features/locations/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';
import { showAlert } from '../../src/lib/dialog';

// Only the owner can see these. Staff cannot read saved addresses.
export default function Addresses() {
  const router = useRouter();
  const [rows, setRows] = useState<SavedAddress[] | null>(null);
  const [places, setPlaces] = useState<Place[]>([]);
  const [error, setError] = useState('');

  const load = useCallback(() => {
    Promise.all([listMyAddresses(), loadPlaces()])
      .then(([a, p]) => { setRows(a); setPlaces(p); setError(''); })
      .catch((e) => { setRows([]); setError(friendlyError(e)); });
  }, []);
  useFocusEffect(load);

  function remove(a: SavedAddress) {
    showAlert('Delete this address?', a.label, [
      { text: 'Keep it', style: 'cancel' },
      { text: 'Delete', style: 'destructive', onPress: () => deleteAddress(a.id).then(load).catch((e) => setError(friendlyError(e))) },
    ]);
  }

  if (!rows) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {rows.length === 0 ? <Notice>You have no saved addresses. Save one so checkout is quicker, or so you can share a pickup spot with a buyer.</Notice> : null}
      {rows.map((a) => {
        const place = places.find((p) => p.id === a.locationId);
        const link = mapsLink(a.latitude, a.longitude);
        return (
          <View key={a.id} style={styles.card}>
            <Text style={styles.title}>{a.label}{a.isDefault ? '  ·  Default' : ''}</Text>
            <Text style={styles.hint}>{ADDRESS_KIND_LABELS[a.kind]}</Text>
            <Text style={styles.body}>{[a.street, a.landmark, place ? formatPlace(place) : null].filter(Boolean).join(', ')}</Text>
            {a.directions ? <Text style={styles.hint}>Directions: {a.directions}</Text> : null}
            <View style={styles.row}>
              <Pressable accessibilityRole="button" onPress={() => router.push({ pathname: '/addresses/edit', params: { id: a.id } })}><Text style={styles.link}>Edit</Text></Pressable>
              {link ? <Pressable accessibilityRole="link" onPress={() => Linking.openURL(link)}><Text style={styles.link}>Open in Maps</Text></Pressable> : null}
              <Pressable accessibilityRole="button" onPress={() => remove(a)}><Text style={styles.danger}>Delete</Text></Pressable>
            </View>
          </View>
        );
      })}
      <Button title="Add an address" onPress={() => router.push('/addresses/edit')} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.text },
  hint: { fontSize: 13, color: colors.muted },
  row: { flexDirection: 'row', gap: spacing.lg, marginTop: spacing.sm },
  link: { fontSize: 14, fontWeight: '600', color: colors.primary },
  danger: { fontSize: 14, fontWeight: '600', color: colors.danger },
});
