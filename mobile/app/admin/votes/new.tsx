import { useRouter } from 'expo-router';
import { useState } from 'react';
import { ScrollView, StyleSheet, Switch, Text, View } from 'react-native';

import { Button, Field, Notice } from '../../../src/components/ui';
import { proposalProblem } from '../../../src/domain/voting';
import { createProposal } from '../../../src/features/voting/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, spacing } from '../../../src/theme';

export default function NewProposal() {
  const router = useRouter();
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [reason, setReason] = useState('');
  const [confidential, setConfidential] = useState(false);
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function save() {
    const problem = proposalProblem({ title, description, reason, confirmedNoOverride: confirmed });
    if (problem) {
      setError(problem);
      return;
    }
    setBusy(true);
    setError('');
    try {
      const id = await createProposal({ title, description, reason, confidential });
      router.replace(`/admin/votes/${id}`);
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.text}>The proposal is saved as a draft first. You choose when voting opens and closes on the next screen.</Text>
      <Field label="Title" value={title} onChangeText={setTitle} maxLength={120} />
      <Field label="What is being decided" value={description} onChangeText={setDescription} multiline numberOfLines={5} maxLength={4000} style={styles.multi} />
      <Field label="Why it is needed" value={reason} onChangeText={setReason} multiline numberOfLines={4} maxLength={2000} style={styles.multi} />

      <View style={styles.switchRow}>
        <View style={styles.switchText}>
          <Text style={styles.label}>Confidential matter</Text>
          <Text style={styles.hint}>Running counts stay hidden until the vote closes, and individual votes are never shown to anyone.</Text>
        </View>
        <Switch accessibilityLabel="Confidential matter" value={confidential} onValueChange={setConfidential} />
      </View>

      <View style={styles.switchRow}>
        <View style={styles.switchText}>
          <Text style={styles.label}>No override</Text>
          <Text style={styles.hint}>I confirm this does not ask staff to override a legal requirement, a security control or an emergency responsibility. A vote cannot do that.</Text>
        </View>
        <Switch accessibilityLabel="Confirm this does not override legal, security or emergency duties" value={confirmed} onValueChange={setConfirmed} />
      </View>

      <Button title="Save draft" onPress={save} loading={busy} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  multi: { minHeight: 100, textAlignVertical: 'top' },
  switchRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  switchText: { flex: 1, gap: 2 },
  label: { fontSize: 15, fontWeight: '600', color: colors.text },
  hint: { fontSize: 13, lineHeight: 18, color: colors.muted },
});
