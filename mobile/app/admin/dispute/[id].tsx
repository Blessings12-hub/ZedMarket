import { useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice, SectionTitle } from '../../../src/components/ui';
import { reasonProblem } from '../../../src/domain/admin';
import { decideDispute } from '../../../src/features/admin/api';
import { DISPUTE_STATUS_LABELS, fetchDispute, fetchEvidence, signedUrl, type Dispute, type Evidence } from '../../../src/features/trust/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

type Decision = 'awaiting_info' | 'resolved' | 'rejected';

const DECISIONS: { value: Decision; label: string; prompt: string }[] = [
  { value: 'awaiting_info', label: 'Ask for more information', prompt: 'What do you need from them?' },
  { value: 'resolved', label: 'Resolve the dispute', prompt: 'What was decided? Both people will see this.' },
  { value: 'rejected', label: 'Close without action', prompt: 'Why is it being closed? Both people will see this.' },
];

export default function StaffDispute() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [dispute, setDispute] = useState<Dispute | null>(null);
  const [evidence, setEvidence] = useState<Evidence[]>([]);
  const [links, setLinks] = useState<Record<string, string>>({});
  const [decision, setDecision] = useState<Decision | null>(null);
  const [outcome, setOutcome] = useState('');
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
    } catch (err) {
      setError(friendlyError(err));
    }
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  async function submit() {
    if (!id || !decision) return;
    const problem = reasonProblem(outcome);
    if (problem) {
      setError(problem);
      return;
    }
    setBusy(true);
    setError('');
    try {
      await decideDispute(id, decision, outcome);
      router.back();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!dispute) {
    return <View style={styles.center}>{error ? <Notice tone="error">{error}</Notice> : <Text style={styles.text}>Loading</Text>}</View>;
  }

  const chosen = DECISIONS.find((d) => d.value === decision);

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}

      <View style={styles.card}>
        <Text style={styles.status}>{DISPUTE_STATUS_LABELS[dispute.status]}</Text>
        <Text style={styles.title}>{dispute.reason}</Text>
        {dispute.details ? <Text style={styles.text}>{dispute.details}</Text> : null}
        <Text style={styles.meta}>Opened {new Date(dispute.createdAt).toLocaleString()}</Text>
        {dispute.outcome ? <Text style={styles.meta}>Last note: {dispute.outcome}</Text> : null}
      </View>

      <SectionTitle>Evidence</SectionTitle>
      {evidence.length === 0 ? <Text style={styles.meta}>Nothing has been added yet.</Text> : null}
      {evidence.map((e) => (
        <View key={e.id} style={styles.card}>
          <Text style={styles.meta}>
            {e.uploaderId === dispute.openedBy ? 'Person who opened the dispute' : 'The other person'} · {new Date(e.createdAt).toLocaleString()}
          </Text>
          {e.note ? <Text style={styles.text}>{e.note}</Text> : null}
          {links[e.id] ? <Image source={{ uri: links[e.id] }} style={styles.photo} resizeMode="contain" /> : null}
        </View>
      ))}

      {chosen ? (
        <View style={styles.card}>
          <SectionTitle>{chosen.label}</SectionTitle>
          <Field label={chosen.prompt} value={outcome} onChangeText={setOutcome} multiline maxLength={500} style={{ minHeight: 100, textAlignVertical: 'top' }} />
          <Button title={chosen.label} onPress={submit} loading={busy} />
          <Button title="Back" variant="secondary" onPress={() => setDecision(null)} disabled={busy} />
        </View>
      ) : (
        <View style={{ gap: spacing.sm }}>
          {DECISIONS.map((d) => (
            <Button
              key={d.value}
              title={d.label}
              variant={d.value === 'resolved' ? 'primary' : 'secondary'}
              onPress={() => {
                setDecision(d.value);
                setOutcome('');
                setError('');
              }}
            />
          ))}
        </View>
      )}
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
  text: { fontSize: 15, lineHeight: 22, color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
  photo: { width: '100%', height: 240, backgroundColor: colors.primarySoft, borderRadius: radius.sm },
});
