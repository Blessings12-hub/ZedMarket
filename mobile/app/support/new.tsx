import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { ScrollView, StyleSheet, Text } from 'react-native';

import { Button, Chip, Field, Notice } from '../../src/components/ui';
import { ticketFormProblem } from '../../src/domain/support';
import { fetchCategories, openTicket, type Category } from '../../src/features/support/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, spacing } from '../../src/theme';

export default function NewTicket() {
  const router = useRouter();
  const { orderId } = useLocalSearchParams<{ orderId?: string }>();
  const [categories, setCategories] = useState<Category[]>([]);
  const [category, setCategory] = useState(orderId ? 'order_problem' : '');
  const [subject, setSubject] = useState('');
  const [description, setDescription] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    fetchCategories().then(setCategories).catch((e) => setError(friendlyError(e)));
  }, []);

  async function submit() {
    if (!category) { setError('Choose what the problem is about.'); return; }
    const problem = ticketFormProblem(subject, description);
    if (problem) { setError(problem); return; }
    setBusy(true);
    setError('');
    try {
      const id = await openTicket(category, subject.trim(), description.trim(), orderId ?? null);
      router.replace(`/support/${id}`);
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  const chosen = categories.find((c) => c.key === category);

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.label}>What is it about?</Text>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: spacing.sm }}>
        {categories.map((c) => <Chip key={c.key} label={c.label} selected={category === c.key} onPress={() => setCategory(c.key)} />)}
      </ScrollView>
      {chosen ? <Text style={styles.hint}>{chosen.hint}</Text> : null}
      {orderId ? <Notice>This will be linked to your order, so our team can see it.</Notice> : null}
      <Field label="Short title" value={subject} onChangeText={setSubject} maxLength={120} />
      <Field label="What happened?" value={description} onChangeText={setDescription} multiline maxLength={2000} style={{ minHeight: 140, textAlignVertical: 'top' }} />
      <Text style={styles.hint}>Never send your PIN or password. We will never ask for them. You can add photos after you send this.</Text>
      <Button title="Send" onPress={submit} loading={busy} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  label: { fontSize: 15, fontWeight: '700', color: colors.text },
  hint: { fontSize: 13, color: colors.muted, lineHeight: 19 },
});
