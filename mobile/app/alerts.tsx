import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Notice, SectionTitle } from '../src/components/ui';
import { formatKwacha } from '../src/domain/money';
import {
  deleteSavedSearch,
  fetchAlerts,
  fetchSavedSearches,
  markAlertRead,
} from '../src/features/listings/api';
import type { ListingAlert, SavedSearch } from '../src/features/listings/types';
import { friendlyError } from '../src/lib/errors';
import { colors, radius, spacing } from '../src/theme';
import { showAlert } from '../src/lib/dialog';

// New listings that match a saved search land here. Push, SMS and email delivery
// come with the notifications module; until then this list is the alert.
export default function AlertsScreen() {
  const router = useRouter();
  const [alerts, setAlerts] = useState<ListingAlert[]>([]);
  const [searches, setSearches] = useState<SavedSearch[]>([]);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    try {
      const [a, s] = await Promise.all([fetchAlerts(), fetchSavedSearches()]);
      setAlerts(a);
      setSearches(s);
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  async function openAlert(alert: ListingAlert) {
    if (!alert.read) {
      setAlerts((prev) => prev.map((a) => (a.id === alert.id ? { ...a, read: true } : a)));
      await markAlertRead(alert.id).catch(() => undefined);
    }
    router.push(`/listing/${alert.listingId}`);
  }

  function removeSearch(search: SavedSearch) {
    showAlert('Delete this saved search?', `${search.name}\nIts alerts will be removed too.`, [
      { text: 'Keep it', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: async () => {
          try {
            await deleteSavedSearch(search.id);
            await load();
          } catch (e) {
            showAlert('Could not delete it', friendlyError(e));
          }
        },
      },
    ]);
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}

      <SectionTitle>New matches</SectionTitle>
      {alerts.length === 0 ? (
        <Text style={styles.empty}>Nothing new yet. Search for something, then tap "Alert me about new matches".</Text>
      ) : (
        alerts.map((a) => (
          <Pressable key={a.id} accessibilityRole="button" style={[styles.card, !a.read && styles.unread]} onPress={() => openAlert(a)}>
            <Text style={styles.title}>{a.title}</Text>
            <Text style={styles.meta}>
              {formatKwacha(a.price)} · matches "{a.searchName}" · {new Date(a.createdAt).toLocaleDateString('en-ZM')}
            </Text>
          </Pressable>
        ))
      )}

      <SectionTitle>Your saved searches</SectionTitle>
      {searches.length === 0 ? (
        <Text style={styles.empty}>You have not saved any searches. You can keep up to 10.</Text>
      ) : (
        searches.map((s) => (
          <View key={s.id} style={styles.card}>
            <Text style={styles.title}>{s.name}</Text>
            <Pressable accessibilityRole="button" onPress={() => removeSearch(s)}>
              <Text style={styles.remove}>Delete</Text>
            </Pressable>
          </View>
        ))
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.xs },
  unread: { borderColor: colors.primary, borderWidth: 2 },
  title: { fontSize: 16, fontWeight: '600', color: colors.text },
  meta: { fontSize: 13, color: colors.muted },
  remove: { color: colors.danger, fontWeight: '600', marginTop: spacing.xs },
  empty: { color: colors.muted },
});
