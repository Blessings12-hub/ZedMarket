import { useLocalSearchParams, useRouter } from 'expo-router';
import { useState } from 'react';
import { ScrollView, StyleSheet, Text } from 'react-native';

import { Button, Field, Notice } from '../../src/components/ui';
import { validateDispute } from '../../src/domain/trust';
import { fetchDisputeForOrder, openDispute } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, spacing } from '../../src/theme';

export default function OpenDispute() {
  const { orderId } = useLocalSearchParams<{ orderId: string }>();
  const router = useRouter();
  const [reason, setReason] = useState('');
  const [details, setDetails] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit() {
    const problem = validateDispute(reason, details);
    if (problem || !orderId) {
      setError(problem ?? 'Something is missing.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      await openDispute(orderId, reason, details);
      const dispute = await fetchDisputeForOrder(orderId);
      if (dispute) router.replace(`/dispute/${dispute.id}`);
      else router.back();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.text}>
        Tell us what went wrong. Our team will look at it and may ask both of you for more information. You can add photos and notes on the next screen.
      </Text>
      <Field label="What went wrong? (short)" value={reason} onChangeText={setReason} maxLength={200} />
      <Field
        label="Details (optional)"
        value={details}
        onChangeText={setDetails}
        multiline
        maxLength={2000}
        style={{ minHeight: 120, textAlignVertical: 'top' }}
      />
      <Button title="Open a dispute" onPress={submit} loading={busy} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
});
