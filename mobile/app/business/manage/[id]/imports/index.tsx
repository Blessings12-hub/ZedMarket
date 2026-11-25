import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Notice, SectionTitle } from '../../../../../src/components/ui';
import { CONDITION_HELP, STATUS_LABELS, TEMPLATE_CSV, parseImportText } from '../../../../../src/domain/bulkImport';
import { createImport, fetchImportHistory, type ImportHistoryItem } from '../../../../../src/features/imports/api';
import { friendlyError } from '../../../../../src/lib/errors';
import { colors, radius, spacing } from '../../../../../src/theme';

export default function ImportProducts() {
  const router = useRouter();
  const { id } = useLocalSearchParams<{ id: string }>();
  const [text, setText] = useState('');
  const [name, setName] = useState('products.csv');
  const [history, setHistory] = useState<ImportHistoryItem[]>([]);
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);

  useFocusEffect(
    useCallback(() => {
      if (id) fetchImportHistory(id).then(setHistory).catch((e) => setError(friendlyError(e)));
    }, [id]),
  );

  async function check() {
    setError('');
    setNote('');
    const parsed = parseImportText(text);
    if (!parsed.ok) return setError(parsed.message);
    if (parsed.ignoredColumns.length > 0) setNote(`Ignored columns: ${parsed.ignoredColumns.join(', ')}.`);
    setBusy(true);
    try {
      const format = name.toLowerCase().endsWith('.xlsx') ? 'xlsx' : 'csv';
      const job = await createImport(String(id), name.trim() || 'products.csv', format, parsed.rows);
      setText('');
      router.push({ pathname: '/business/manage/[id]/imports/[job]', params: { id: String(id), job } });
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {note ? <Notice>{note}</Notice> : null}
      <Text style={styles.title}>Import products</Text>
      <Text style={styles.text}>
        Paste your list as CSV, or copy the cells from Excel and paste them here. The first row must be the column names. Nothing is added until you have
        seen the check and sent it. Products arrive as drafts: add photos and publish them from your listings.
      </Text>
      <Text style={styles.text}>{`Required columns: sku, title, price_zmw, category (slug), condition (${CONDITION_HELP}), quantity. Optional: description, low_stock_at, warranty_info, return_policy.`}</Text>
      <Button title="Use the example" variant="secondary" onPress={() => setText(TEMPLATE_CSV)} />
      <Field label="File name" value={name} onChangeText={setName} autoCapitalize="none" />
      <Field label="Your list" value={text} onChangeText={setText} multiline numberOfLines={8} autoCapitalize="none" style={{ minHeight: 160, textAlignVertical: 'top' }} />
      <Button title="Check my list" onPress={check} loading={busy} disabled={text.trim() === ''} />

      <SectionTitle>Past imports</SectionTitle>
      {history.length === 0 ? <Text style={styles.text}>No imports yet.</Text> : null}
      {history.map((h) => (
        <View key={h.id} style={styles.card}>
          <Text style={styles.name}>{h.fileName}</Text>
          <Text style={styles.text}>{`${STATUS_LABELS[h.status]} · ${h.imported} added, ${h.failed} failed, ${h.notAdded} skipped of ${h.totalRows}`}</Text>
          <Text style={styles.small}>{`${h.by} · ${h.createdAt.slice(0, 16).replace('T', ' ')}${h.resubmitOf ? ' · retry' : ''}`}</Text>
          <Button title="Open" variant="secondary" onPress={() => router.push({ pathname: '/business/manage/[id]/imports/[job]', params: { id: String(id), job: h.id } })} />
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  small: { fontSize: 13, color: colors.muted },
  name: { fontSize: 16, fontWeight: '700', color: colors.text },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
});
