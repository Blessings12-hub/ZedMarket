import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { PlacePicker } from '../../src/components/PlacePicker';
import { Button, Chip, Notice, SectionTitle } from '../../src/components/ui';
import { COVERAGE_LEVEL_LABELS, formatPlace, type CoverageLevel, type Place } from '../../src/domain/locations';
import { fetchMyDeliveryAreas, saveDeliveryAreas } from '../../src/features/locations/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

type Row = { locationId: number; level: CoverageLevel; label: string };

// Where a seller (or a business, when a businessId is passed) delivers. Leave it empty to deliver anywhere,
// and agree each delivery with the buyer. Add places to limit it.
export default function DeliveryAreas() {
  const { businessId } = useLocalSearchParams<{ businessId?: string }>();
  const biz = businessId ?? null;
  const [rows, setRows] = useState<Row[] | null>(null);
  const [pick, setPick] = useState<Place | null>(null);
  const [level, setLevel] = useState<CoverageLevel>('area');
  const [error, setError] = useState('');
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    fetchMyDeliveryAreas(biz).then(setRows).catch((e) => { setRows([]); setError(friendlyError(e)); });
  }, [biz]);

  function add() {
    if (!pick || !rows) return;
    const label = level === 'province' ? `${pick.province} Province` : level === 'district' ? `${pick.district ?? pick.town} district` : level === 'town' ? pick.town : formatPlace(pick);
    if (rows.some((r) => r.locationId === pick.id && r.level === level)) return;
    setRows([...rows, { locationId: pick.id, level, label }]);
    setSaved(false);
  }

  async function save() {
    if (!rows) return;
    setBusy(true);
    setError('');
    try {
      await saveDeliveryAreas(biz, rows);
      setSaved(true);
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!rows) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Notice>
        {rows.length === 0
          ? 'You have not limited where you deliver, so buyers anywhere can ask for delivery and you decide each time.'
          : 'Buyers can only ask for delivery to the places below. Remove them all to deliver anywhere.'}
      </Notice>
      {rows.map((r) => (
        <View key={`${r.locationId}-${r.level}`} style={styles.card}>
          <View style={{ flex: 1 }}>
            <Text style={styles.title}>{r.label}</Text>
            <Text style={styles.hint}>{COVERAGE_LEVEL_LABELS[r.level]}</Text>
          </View>
          <Pressable accessibilityRole="button" onPress={() => { setRows(rows.filter((x) => x !== r)); setSaved(false); }}>
            <Text style={styles.remove}>Remove</Text>
          </Pressable>
        </View>
      ))}
      <SectionTitle>Add a place</SectionTitle>
      <PlacePicker value={pick?.id ?? null} onChange={(_, p) => setPick(p)} label="Where do you deliver?" />
      <View style={styles.chips}>
        {(Object.keys(COVERAGE_LEVEL_LABELS) as CoverageLevel[]).map((l) => (
          <Chip key={l} label={COVERAGE_LEVEL_LABELS[l]} selected={level === l} onPress={() => setLevel(l)} />
        ))}
      </View>
      <Button title="Add to my list" variant="secondary" onPress={add} disabled={!pick} />
      {error ? <Notice tone="error">{error}</Notice> : null}
      {saved ? <Notice>Saved.</Notice> : null}
      <Button title="Save delivery places" onPress={save} loading={busy} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl },
  card: { flexDirection: 'row', alignItems: 'center', backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg },
  title: { fontSize: 15, fontWeight: '600', color: colors.text },
  hint: { fontSize: 13, color: colors.muted },
  remove: { fontSize: 14, fontWeight: '600', color: colors.danger },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
});
