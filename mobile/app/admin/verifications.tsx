import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, Image, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice } from '../../src/components/ui';
import { reasonProblem } from '../../src/domain/admin';
import { decideVerification, fetchPendingVerifications, type VerificationItem } from '../../src/features/admin/api';
import { signedUrl } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function VerificationQueue() {
  const [items, setItems] = useState<VerificationItem[]>([]);
  const [images, setImages] = useState<Record<string, string>>({});
  const [rejectingId, setRejectingId] = useState<string | null>(null);
  const [note, setNote] = useState('');
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      setItems(await fetchPendingVerifications());
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

  async function showDocument(item: VerificationItem) {
    if (!item.documentPath) return;
    try {
      const bucket = item.kind === 'identity' ? 'identity-documents' : 'business-documents';
      const url = await signedUrl(bucket, item.documentPath);
      setImages((current) => ({ ...current, [item.id]: url }));
    } catch (e) {
      setError(friendlyError(e));
    }
  }

  async function decide(item: VerificationItem, approve: boolean) {
    if (!approve) {
      const problem = reasonProblem(note);
      if (problem) {
        setError(problem);
        return;
      }
    }
    setBusyId(item.id);
    setError('');
    try {
      await decideVerification(item, approve, note);
      setRejectingId(null);
      setNote('');
      await load();
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
      <FlatList
        data={items}
        keyExtractor={(i) => `${i.kind}-${i.id}`}
        refreshing={loading}
        onRefresh={load}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, flexGrow: 1 }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>No verification requests are waiting.</Text>}
        renderItem={({ item }) => {
          const busy = busyId === item.id;
          return (
            <View style={styles.card}>
              <Text style={styles.kind}>{item.kind === 'identity' ? 'Identity check' : 'Business check'}</Text>
              <Text style={styles.title}>{item.title}</Text>
              <Text style={styles.text}>{item.detail}</Text>
              <Text style={styles.meta}>{new Date(item.submittedAt).toLocaleString()}</Text>

              {images[item.id] ? (
                <Image source={{ uri: images[item.id] }} style={styles.photo} resizeMode="contain" />
              ) : item.documentPath ? (
                <Button title="Show the document" variant="secondary" onPress={() => showDocument(item)} />
              ) : (
                <Text style={styles.meta}>No document was attached.</Text>
              )}

              {rejectingId === item.id ? (
                <>
                  <Field
                    label="What is wrong? The person will see this."
                    value={note}
                    onChangeText={setNote}
                    multiline
                    maxLength={500}
                    style={{ minHeight: 80, textAlignVertical: 'top' }}
                  />
                  <Button title="Reject" variant="danger" onPress={() => decide(item, false)} loading={busy} />
                  <Button title="Back" variant="secondary" onPress={() => setRejectingId(null)} disabled={busy} />
                </>
              ) : (
                <>
                  <Button title="Approve" onPress={() => decide(item, true)} loading={busy} />
                  <Button
                    title="Reject"
                    variant="secondary"
                    onPress={() => {
                      setRejectingId(item.id);
                      setNote('');
                      setError('');
                    }}
                    disabled={busy}
                  />
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
  kind: { fontSize: 13, color: colors.muted },
  title: { fontSize: 17, fontWeight: '600', color: colors.text },
  text: { fontSize: 15, color: colors.text, textTransform: 'capitalize' },
  meta: { fontSize: 12, color: colors.muted },
  photo: { width: '100%', height: 260, backgroundColor: colors.primarySoft, borderRadius: radius.sm },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
