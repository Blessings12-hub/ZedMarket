import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice, SectionTitle } from '../../../../src/components/ui';
import { phoneProblem } from '../../../../src/domain/business';
import { createBranch, fetchBranches, saveBranch, type Branch } from '../../../../src/features/business/api';
import { friendlyError } from '../../../../src/lib/errors';
import { colors, radius, spacing } from '../../../../src/theme';

export default function Branches() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [items, setItems] = useState<Branch[]>([]);
  const [name, setName] = useState('');
  const [address, setAddress] = useState('');
  const [phone, setPhone] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!id) return;
    try {
      setItems(await fetchBranches(id));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [id]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  async function run(action: () => Promise<unknown>) {
    setBusy(true);
    setError('');
    try {
      await action();
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  function add() {
    const problem = phoneProblem(phone);
    if (name.trim().length < 2) return setError('Give the branch a name.');
    if (problem) return setError(problem);
    run(async () => {
      await createBranch(id!, name, address, phone, false);
      setName('');
      setAddress('');
      setPhone('');
    });
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Notice>Branches show on your public page. Each listing can say which branch holds the item, and orders remember it.</Notice>
      {items.map((b) => (
        <View key={b.id} style={styles.card}>
          <Text style={styles.name}>{b.name}{b.isMain ? ' (main)' : ''}{b.active ? '' : ' (switched off)'}</Text>
          {b.address ? <Text style={styles.text}>{b.address}</Text> : null}
          {b.phone ? <Text style={styles.text}>{b.phone}</Text> : null}
          {!b.isMain && b.active ? <Button title="Make main branch" variant="secondary" disabled={busy} onPress={() => run(() => saveBranch(b, { isMain: true }))} /> : null}
          {!b.isMain ? (
            <Button title={b.active ? 'Switch off' : 'Switch on'} variant="secondary" disabled={busy} onPress={() => run(() => saveBranch(b, { active: !b.active }))} />
          ) : null}
        </View>
      ))}
      <SectionTitle>Add a branch</SectionTitle>
      <Field label="Branch name" value={name} onChangeText={setName} maxLength={60} />
      <Field label="Address (optional)" value={address} onChangeText={setAddress} maxLength={200} />
      <Field label="Phone (optional)" value={phone} onChangeText={setPhone} keyboardType="phone-pad" />
      <Button title="Add branch" onPress={add} loading={busy} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  name: { fontSize: 16, fontWeight: '600', color: colors.text },
  text: { fontSize: 14, color: colors.text },
});
