import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';

import { PlacePicker } from '../../src/components/PlacePicker';
import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { ADDRESS_KIND_LABELS, parseCoordinates, validateAddress, type AddressKind } from '../../src/domain/locations';
import { listMyAddresses, saveAddress } from '../../src/features/locations/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, spacing } from '../../src/theme';

export default function EditAddress() {
  const { id } = useLocalSearchParams<{ id?: string }>();
  const router = useRouter();
  const [label, setLabel] = useState('');
  const [kind, setKind] = useState<AddressKind>('both');
  const [locationId, setLocationId] = useState<number | null>(null);
  const [street, setStreet] = useState('');
  const [landmark, setLandmark] = useState('');
  const [directions, setDirections] = useState('');
  const [isDefault, setIsDefault] = useState(false);
  const [latText, setLatText] = useState('');
  const [lngText, setLngText] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!id) return;
    listMyAddresses()
      .then((rows) => {
        const a = rows.find((r) => r.id === id);
        if (!a) return;
        setLabel(a.label); setKind(a.kind); setLocationId(a.locationId); setStreet(a.street ?? '');
        setLandmark(a.landmark ?? ''); setDirections(a.directions ?? ''); setIsDefault(a.isDefault);
        setLatText(a.latitude === null ? '' : String(a.latitude)); setLngText(a.longitude === null ? '' : String(a.longitude));
      })
      .catch((e) => setError(friendlyError(e)));
  }, [id]);

  async function submit() {
    const problem = validateAddress({ label, kind, locationId, street, landmark, directions });
    if (problem || locationId === null) { setError(problem ?? 'Choose the town or area.'); return; }
    const c = parseCoordinates(latText, lngText);
    if (c.problem) { setError(c.problem); return; }
    setBusy(true);
    setError('');
    try {
      await saveAddress({ id: id ?? null, label, kind, locationId, street, landmark, directions, isDefault, latitude: c.lat, longitude: c.lng });
      router.back();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      <Field label="Name for this address" value={label} onChangeText={setLabel} placeholder="Home, Shop, Office" maxLength={40} />
      <SectionTitle>What is it for?</SectionTitle>
      <View style={styles.row}>
        {(Object.keys(ADDRESS_KIND_LABELS) as AddressKind[]).map((k) => (
          <Chip key={k} label={ADDRESS_KIND_LABELS[k]} selected={kind === k} onPress={() => setKind(k)} />
        ))}
      </View>
      <PlacePicker value={locationId} onChange={(i) => setLocationId(i)} allowTownOnly label="Town or area" />
      <Field label="Street or plot (optional if you add a landmark)" value={street} onChangeText={setStreet} maxLength={150} />
      <Field label="Landmark" value={landmark} onChangeText={setLandmark} placeholder="For example: opposite the filling station" maxLength={150} />
      <Field label="Directions for a driver or buyer (optional)" value={directions} onChangeText={setDirections} multiline maxLength={300} />
      <Field label="Exact position (optional)" value={latText} onChangeText={setLatText} placeholder="Latitude, for example -15.4167" keyboardType="numbers-and-punctuation" />
      <Field label="" value={lngText} onChangeText={setLngText} placeholder="Longitude, for example 28.2833" keyboardType="numbers-and-punctuation" />
      <Notice>To get these, open the place in your Maps app, press and hold it, and copy the two numbers. Buyers then get an "Open in Maps" link.</Notice>
      <View style={styles.row}>
        <Chip label={isDefault ? 'Default address ✓' : 'Make this my default'} selected={isDefault} onPress={() => setIsDefault(!isDefault)} />
      </View>
      <Notice>Only you can see your saved addresses. A seller sees a delivery address only on an order you send them, and a buyer sees a pickup address only if you share it on a confirmed order.</Notice>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Button title="Save address" onPress={submit} loading={busy} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
});
