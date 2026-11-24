import { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { areasIn, districtsIn, formatPlace, provinces, townsIn, type Place } from '../domain/locations';
import { loadPlaces } from '../features/locations/api';
import { colors, spacing } from '../theme';
import { Chip, Notice } from './ui';

type Props = {
  value: number | null;
  onChange: (id: number | null, place: Place | null) => void;
  // When true the town on its own (no named area) can be chosen. Delivery areas use this; addresses need a place.
  allowTownOnly?: boolean;
  label?: string;
};

// Province -> district -> town -> area. Plain chips, so it works on a small screen and a slow connection.
export function PlacePicker({ value, onChange, label = 'Where?', allowTownOnly = true }: Props) {
  const [places, setPlaces] = useState<Place[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [province, setProvince] = useState<string | null>(null);
  const [district, setDistrict] = useState<string | null>(null);
  const [town, setTown] = useState<string | null>(null);

  useEffect(() => {
    loadPlaces().then(setPlaces).catch(() => setFailed(true));
  }, []);

  // Open on the current value's branch.
  useEffect(() => {
    if (!places || value === null) return;
    const p = places.find((x) => x.id === value);
    if (p) {
      setProvince(p.province);
      setDistrict(p.district);
      setTown(p.town);
    }
  }, [places, value]);

  if (failed) return <Notice tone="error">Could not load places. Check your connection and try again.</Notice>;
  if (!places) return <Text style={styles.hint}>Loading places…</Text>;

  const chosen = value !== null ? places.find((p) => p.id === value) : null;
  const districts = province ? districtsIn(places, province) : [];
  const towns = province && district ? townsIn(places, province, district) : [];
  const areas = province && district && town ? areasIn(places, province, district, town) : [];

  return (
    <View style={styles.box}>
      <Text style={styles.label}>{label}</Text>
      <Text style={styles.step}>Province</Text>
      <View style={styles.row}>
        {provinces(places).map((p) => (
          <Chip key={p} label={p} selected={province === p} onPress={() => { setProvince(p); setDistrict(null); setTown(null); onChange(null, null); }} />
        ))}
      </View>
      {province ? (
        <>
          <Text style={styles.step}>District</Text>
          <View style={styles.row}>
            {districts.map((d) => (
              <Chip key={d} label={d} selected={district === d} onPress={() => { setDistrict(d); setTown(null); onChange(null, null); }} />
            ))}
          </View>
        </>
      ) : null}
      {district ? (
        <>
          <Text style={styles.step}>Town</Text>
          <View style={styles.row}>
            {towns.map((t) => (
              <Chip key={t} label={t} selected={town === t} onPress={() => { setTown(t); onChange(null, null); }} />
            ))}
          </View>
        </>
      ) : null}
      {town ? (
        <>
          <Text style={styles.step}>Area</Text>
          <View style={styles.row}>
            {areas
              .filter((a) => a.area !== null || allowTownOnly)
              .map((a) => (
                <Chip key={a.id} label={a.area ?? `All of ${a.town}`} selected={value === a.id} onPress={() => onChange(a.id, a)} />
              ))}
          </View>
        </>
      ) : null}
      {chosen ? <Text style={styles.chosen}>Chosen: {formatPlace(chosen)} ({chosen.province})</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  box: { gap: spacing.xs },
  label: { fontSize: 14, fontWeight: '600', color: colors.text },
  step: { fontSize: 12, color: colors.muted, marginTop: spacing.xs },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  hint: { fontSize: 13, color: colors.muted },
  chosen: { fontSize: 13, color: colors.text, marginTop: spacing.xs },
});
