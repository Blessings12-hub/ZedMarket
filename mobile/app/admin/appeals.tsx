import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice } from '../../src/components/ui';
import { reasonProblem } from '../../src/domain/admin';
import { approveListing, changeAccountState, decideAppeal, fetchOpenAppeals, type StaffAppeal } from '../../src/features/admin/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

type Pending = { id: string; status: 'upheld' | 'overturned' };

export default function AppealQueue() {
  const [items, setItems] = useState<StaffAppeal[]>([]);
  const [pending, setPending] = useState<Pending | null>(null);
  const [note, setNote] = useState('');
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');
  const [busyId, setBusyId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      setItems(await fetchOpenAppeals());
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  async function submit(appeal: StaffAppeal) {
    if (!pending) return;
    const problem = reasonProblem(note);
    if (problem) {
      setError(problem);
      return;
    }
    setBusyId(appeal.id);
    setError('');
    try {
      await decideAppeal(appeal.id, pending.status, note);
      setMessage(
        pending.status === 'overturned' && (appeal.targetType === 'listing' || appeal.targetType === 'user')
          ? 'Appeal recorded. Use the button on that appeal to put the listing or account back.'
          : 'Appeal recorded.',
      );
      setPending(null);
      setNote('');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusyId(null);
    }
  }

  // Overturning an appeal records the decision. Putting things back is a separate, logged action.
  async function putBack(appeal: StaffAppeal) {
    setBusyId(appeal.id);
    setError('');
    try {
      if (appeal.targetType === 'listing') await approveListing(appeal.targetId, 'Appeal overturned');
      if (appeal.targetType === 'user') await changeAccountState(appeal.userId, 'active', 'Appeal overturned');
      setMessage('Done.');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <View style={styles.screen}>
      {error ? (
        <View style={{ padding: spacing.lg }}>
          <Notice tone="error">{error}</Notice>
        </View>
      ) : null}
      {message ? (
        <View style={{ paddingHorizontal: spacing.lg, paddingTop: spacing.lg }}>
          <Notice>{message}</Notice>
        </View>
      ) : null}
      <FlatList
        data={items}
        keyExtractor={(a) => a.id}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, flexGrow: 1 }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>No appeals are waiting.</Text>}
        renderItem={({ item }) => {
          const busy = busyId === item.id;
          const deciding = pending?.id === item.id;
          return (
            <View style={styles.card}>
              <Text style={styles.meta}>
                {item.userName} · about a {item.targetType} · {new Date(item.createdAt).toLocaleString()}
              </Text>
              <Text style={styles.body}>{item.message}</Text>

              {deciding ? (
                <>
                  <Field
                    label="Your reply. The person will see this."
                    value={note}
                    onChangeText={setNote}
                    multiline
                    maxLength={500}
                    style={{ minHeight: 80, textAlignVertical: 'top' }}
                  />
                  <Button title={pending?.status === 'overturned' ? 'Overturn the decision' : 'Keep the decision'} onPress={() => submit(item)} loading={busy} />
                  <Button title="Back" variant="secondary" onPress={() => setPending(null)} disabled={busy} />
                </>
              ) : (
                <>
                  <Button
                    title="Overturn the decision"
                    onPress={() => {
                      setPending({ id: item.id, status: 'overturned' });
                      setNote('');
                      setMessage('');
                      setError('');
                    }}
                  />
                  <Button
                    title="Keep the decision"
                    variant="secondary"
                    onPress={() => {
                      setPending({ id: item.id, status: 'upheld' });
                      setNote('');
                      setMessage('');
                      setError('');
                    }}
                  />
                  {item.targetType === 'listing' ? (
                    <Button title="Approve the listing again" variant="secondary" onPress={() => putBack(item)} loading={busy} />
                  ) : null}
                  {item.targetType === 'user' ? (
                    <Button title="Restore the account" variant="secondary" onPress={() => putBack(item)} loading={busy} />
                  ) : null}
                </>
              )}
            </View>
          );
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  meta: { fontSize: 13, color: colors.muted },
  body: { fontSize: 15, lineHeight: 22, color: colors.text },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
