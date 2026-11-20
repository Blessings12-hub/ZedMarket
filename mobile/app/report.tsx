import { useLocalSearchParams, useRouter } from 'expo-router';
import { useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Field, Notice, SectionTitle } from '../src/components/ui';
import { REPORT_REASONS, submitReport, type ReportReason, type ReportTarget } from '../src/features/reports/api';
import { friendlyError } from '../src/lib/errors';
import { colors, spacing } from '../src/theme';

export default function ReportScreen() {
  const { targetType, targetId } = useLocalSearchParams<{ targetType: ReportTarget; targetId: string }>();
  const router = useRouter();

  const [reason, setReason] = useState<ReportReason | null>(null);
  const [details, setDetails] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);

  async function submit() {
    if (!reason || !targetType || !targetId) {
      setError('Choose what is wrong first.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      await submitReport(targetType, targetId, reason, details);
      setSent(true);
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (sent) {
    return (
      <View style={styles.done}>
        <Text style={styles.title}>Thank you</Text>
        <Text style={styles.text}>Our team will look at your report. We may remove the listing or restrict the account if it breaks our rules.</Text>
        <Button title="Done" onPress={() => router.back()} />
      </View>
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      <SectionTitle>What is the problem?</SectionTitle>
      <View style={styles.row}>
        {REPORT_REASONS.map((r) => (
          <Chip key={r.value} label={r.label} selected={reason === r.value} onPress={() => setReason(r.value)} />
        ))}
      </View>
      <Field
        label="Anything else we should know? (optional)"
        value={details}
        onChangeText={setDetails}
        multiline
        maxLength={1000}
        style={{ minHeight: 100, textAlignVertical: 'top' }}
      />
      <Button title="Send report" onPress={submit} loading={busy} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  done: { flex: 1, padding: spacing.xl, gap: spacing.lg, justifyContent: 'center', backgroundColor: colors.background },
  title: { fontSize: 24, fontWeight: '700', color: colors.text },
  text: { fontSize: 16, lineHeight: 24, color: colors.muted },
});
