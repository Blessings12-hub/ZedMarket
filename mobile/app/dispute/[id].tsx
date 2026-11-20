import { useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Field, Notice, SectionTitle } from '../../src/components/ui';
import {
  addEvidenceNote,
  addEvidencePhoto,
  DISPUTE_STATUS_LABELS,
  fetchDispute,
  fetchEvidence,
  pickOnePhoto,
  signedUrl,
  type Dispute,
  type Evidence,
} from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function DisputeScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { userId } = useAuth();
  const [dispute, setDispute] = useState<Dispute | null>(null);
  const [evidence, setEvidence] = useState<Evidence[]>([]);
  const [links, setLinks] = useState<Record<string, string>>({});
  const [note, setNote] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const [d, e] = await Promise.all([fetchDispute(id), fetchEvidence(id)]);
      setDispute(d);
      setEvidence(e);
      const entries = await Promise.all(
        e.filter((x) => x.storagePath).map(async (x) => [x.id, await signedUrl('dispute-evidence', x.storagePath as string)] as const),
      );
      setLinks(Object.fromEntries(entries));
      setError('');
    } catch (err) {
      setError(friendlyError(err));
    }
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  async function sendNote() {
    if (!id || note.trim().length === 0) return;
    setBusy(true);
    try {
      await addEvidenceNote(id, note);
      setNote('');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  async function sendPhoto() {
    if (!id || !userId) return;
    setBusy(true);
    try {
      const uri = await pickOnePhoto();
      if (uri) {
        await addEvidencePhoto(userId, id, uri);
        await load();
      }
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!dispute) {
    return <View style={styles.center}>{error ? <Notice tone="error">{error}</Notice> : <Text style={styles.text}>Loading</Text>}</View>;
  }

  const finished = dispute.status === 'resolved' || dispute.status === 'rejected';

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}

      <View style={styles.card}>
        <Text style={styles.status}>{DISPUTE_STATUS_LABELS[dispute.status]}</Text>
        <Text style={styles.title}>{dispute.reason}</Text>
        {dispute.details ? <Text style={styles.body}>{dispute.details}</Text> : null}
        {dispute.outcome ? <Notice>{dispute.outcome}</Notice> : null}
      </View>

      <SectionTitle>Evidence and notes</SectionTitle>
      {evidence.length === 0 ? <Text style={styles.text}>Nothing added yet.</Text> : null}
      {evidence.map((e) => (
        <View key={e.id} style={styles.card}>
          <Text style={styles.meta}>
            {e.uploaderId === userId ? 'You' : 'The other person'} · {new Date(e.createdAt).toLocaleString()}
          </Text>
          {e.note ? <Text style={styles.body}>{e.note}</Text> : null}
          {links[e.id] ? <Image source={{ uri: links[e.id] }} style={styles.photo} resizeMode="contain" /> : null}
        </View>
      ))}

      {!finished ? (
        <>
          <Field
            label="Add a note"
            value={note}
            onChangeText={setNote}
            multiline
            maxLength={1000}
            style={{ minHeight: 80, textAlignVertical: 'top' }}
          />
          <Button title="Send note" onPress={sendNote} loading={busy} disabled={note.trim().length === 0} />
          <Button title="Add a photo" variant="secondary" onPress={sendPhoto} disabled={busy} />
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, padding: spacing.xl, justifyContent: 'center', backgroundColor: colors.background },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  status: { fontSize: 13, fontWeight: '600', color: colors.primary },
  title: { fontSize: 17, fontWeight: '600', color: colors.text },
  body: { fontSize: 15, lineHeight: 22, color: colors.text },
  text: { fontSize: 15, color: colors.muted },
  meta: { fontSize: 12, color: colors.muted },
  photo: { width: '100%', height: 220, backgroundColor: colors.primarySoft, borderRadius: radius.sm },
});
