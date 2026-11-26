import { useEffect, useState } from 'react';
import { FlatList, Modal, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { areaChoices } from '../features/listings/area';
import type { Place } from '../domain/locations';
import { colors, radius, spacing } from '../theme';
import { Button } from './ui';

type Props = {
  visible: boolean;
  places: Place[];
  province: string;
  selectedId: number | null;
  onPick: (areaId: number | null) => void;
  onClose: () => void;
};

// "Search for items near you": every area of the province, with a box to find one quickly.
export function AreaSheet({ visible, places, province, selectedId, onPick, onClose }: Props) {
  const [query, setQuery] = useState('');
  useEffect(() => { if (visible) setQuery(''); }, [visible]);
  const choices = areaChoices(places, province, query);

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView style={styles.screen}>
        <View style={styles.head}>
          <Text style={styles.title} accessibilityRole="header">Items near you</Text>
          <Pressable accessibilityRole="button" onPress={onClose} hitSlop={10}><Text style={styles.close}>Close</Text></Pressable>
        </View>
        <TextInput
          value={query}
          onChangeText={setQuery}
          placeholder={`Find an area in ${province}`}
          placeholderTextColor={colors.muted}
          style={styles.search}
          autoCapitalize="none"
          maxLength={40}
          accessibilityLabel="Find an area"
        />
        <FlatList
          data={choices}
          keyExtractor={(a) => String(a.id)}
          keyboardShouldPersistTaps="handled"
          contentContainerStyle={{ paddingBottom: spacing.xl }}
          ListHeaderComponent={
            query.trim() === '' ? (
              <Pressable accessibilityRole="button" onPress={() => onPick(null)} style={[styles.row, selectedId === null && styles.rowOn]}>
                <Text style={[styles.rowText, selectedId === null && styles.rowTextOn]}>All of {province}</Text>
              </Pressable>
            ) : null
          }
          ListEmptyComponent={<Text style={styles.empty}>No area matches that. Try another spelling.</Text>}
          renderItem={({ item }) => (
            <Pressable accessibilityRole="button" accessibilityState={{ selected: selectedId === item.id }} onPress={() => onPick(item.id)} style={[styles.row, selectedId === item.id && styles.rowOn]}>
              <Text style={[styles.rowText, selectedId === item.id && styles.rowTextOn]}>{item.label}</Text>
            </Pressable>
          )}
        />
        <View style={{ padding: spacing.lg }}><Button title="Done" variant="secondary" onPress={onClose} /></View>
      </SafeAreaView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  head: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', padding: spacing.lg },
  title: { fontSize: 20, fontWeight: '700', color: colors.text },
  close: { fontSize: 16, fontWeight: '600', color: colors.primary },
  search: { marginHorizontal: spacing.lg, marginBottom: spacing.sm, minHeight: 46, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, backgroundColor: colors.surface, paddingHorizontal: spacing.md, fontSize: 16, color: colors.text },
  row: { minHeight: 52, justifyContent: 'center', paddingHorizontal: spacing.lg, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border },
  rowOn: { backgroundColor: colors.primarySoft },
  rowText: { fontSize: 16, color: colors.text },
  rowTextOn: { fontWeight: '700', color: colors.primaryDark },
  empty: { padding: spacing.lg, color: colors.muted },
});
