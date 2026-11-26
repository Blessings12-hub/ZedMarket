import { useRouter } from 'expo-router';
import { useFocusEffect } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Image, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Field, Notice } from '../../src/components/ui';
import { avatarUrl, changeAvatar, fetchHub, saveProfile } from '../../src/features/account-hub/api';
import { profileProblem } from '../../src/features/account-hub/hub';
import { deliveryLong, pickDeliveryAddress } from '../../src/features/listings/area';
import { listMyAddresses, loadPlaces } from '../../src/features/locations/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, spacing } from '../../src/theme';

export default function EditProfile() {
  const router = useRouter();
  const { userId } = useAuth();
  const [name, setName] = useState('');
  const [bio, setBio] = useState('');
  const [avatar, setAvatar] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [done, setDone] = useState('');
  const [addressId, setAddressId] = useState<string | null>(null);
  const [location, setLocation] = useState<string | null>(null);

  // Re-read every time this screen comes back into view, so the line is right after the address screen closes.
  useFocusEffect(
    useCallback(() => {
      Promise.all([listMyAddresses(), loadPlaces()])
        .then(([rows, places]) => {
          const a = pickDeliveryAddress(rows);
          setAddressId(a?.id ?? null);
          setLocation(deliveryLong(places, a));
        })
        .catch(() => undefined);
    }, []),
  );

  useEffect(() => {
    if (!userId) return;
    fetchHub(userId)
      .then((h) => { setName(h.profile.displayName); setBio(h.profile.bio); setAvatar(h.profile.avatarPath); })
      .catch((e) => setError(friendlyError(e)))
      .finally(() => setLoading(false));
  }, [userId]);

  async function save() {
    if (!userId) return;
    const problem = profileProblem(name, bio);
    if (problem) { setError(problem); setDone(''); return; }
    setBusy(true); setError(''); setDone('');
    try {
      await saveProfile(userId, name, bio);
      setDone('Saved.');
      router.back();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  async function photo() {
    if (!userId) return;
    setBusy(true); setError(''); setDone('');
    try {
      const path = await changeAvatar(userId);
      if (path) { setAvatar(path); setDone('Photo updated.'); }
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (loading) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  const url = avatarUrl(avatar);
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {done ? <Notice>{done}</Notice> : null}
      <View style={styles.photoRow}>
        {url ? <Image source={{ uri: url }} style={styles.avatar} accessibilityLabel="Your profile photo" /> : <View style={[styles.avatar, styles.empty]}><Text style={styles.initial}>{name.trim().slice(0, 1).toUpperCase()}</Text></View>}
        <View style={{ flex: 1 }}><Button title={url ? 'Change photo' : 'Add a photo'} variant="secondary" onPress={photo} disabled={busy} /></View>
      </View>
      <Field label="Name shown to others" value={name} onChangeText={setName} maxLength={60} autoCapitalize="words" />
      <Field label="About you (optional)" value={bio} onChangeText={setBio} maxLength={500} multiline style={{ minHeight: 100, textAlignVertical: 'top' }} />
      <View style={styles.locationCard}>
        <Text style={styles.locationTitle}>Delivery location</Text>
        <Text style={styles.locationLine}>{location ?? 'Not set yet'}</Text>
        <Text style={styles.hint}>This is where your orders are delivered. It shows at the top of Home. Sellers only see it on an order you send them.</Text>
        <Pressable
          accessibilityRole="button"
          onPress={() => router.push(addressId ? { pathname: '/addresses/edit', params: { id: addressId } } : { pathname: '/addresses/edit', params: { preset: 'delivery' } })}
        >
          <Text style={styles.link}>{location ? 'Change delivery location' : 'Set delivery location'}</Text>
        </Pressable>
      </View>
      <Text style={styles.hint}>Your name and about text are shown on your profile, and on your seller page if you sell. Your email and verification documents are never shown there.</Text>
      <Button title="Save" onPress={save} loading={busy} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, justifyContent: 'center', backgroundColor: colors.background },
  photoRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  avatar: { width: 72, height: 72, borderRadius: 36 },
  empty: { backgroundColor: colors.primarySoft, alignItems: 'center', justifyContent: 'center' },
  initial: { fontSize: 28, fontWeight: '700', color: colors.primary },
  locationCard: { backgroundColor: colors.surface, borderRadius: 12, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  locationTitle: { fontSize: 13, fontWeight: '700', color: colors.muted, textTransform: 'uppercase', letterSpacing: 0.5 },
  locationLine: { fontSize: 16, fontWeight: '600', color: colors.text },
  link: { fontSize: 15, fontWeight: '700', color: colors.primary, paddingVertical: spacing.xs },
  hint: { fontSize: 13, color: colors.muted, lineHeight: 18 },
});
