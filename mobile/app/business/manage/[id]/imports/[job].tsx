import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Field, Notice, SectionTitle } from '../../../../../src/components/ui';
import { ROW_LABELS, STATUS_LABELS, canResubmit, isFinished } from '../../../../../src/domain/bulkImport';
import {
  cancelImport, correctImportRow, fetchImportDetail, fetchImportRows, resubmitFailed, submitImport,
  type ImportDetail, type ImportRow,
} from '../../../../../src/features/imports/api';
import { friendlyError } from '../../../../../src/lib/errors';
import { colors, radius, spacing } from '../../../../../src/theme';

const FILTERS: (string | null)[] = [null, 'invalid', 'valid', 'imported', 'failed', 'skipped'];

export default function ImportJob() {
  const router = useRouter();
  const { id, job } = useLocalSearchParams<{ id: string; job: string }>();
  const [detail, setDetail] = useState<ImportDetail | null>(null);
  const [rows, setRows] = useState<ImportRow[]>([]);
  const [filter, setFilter] = useState<string | null>(null);
  const [editing, setEditing] = useState<string | null>(null);
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);

  const load = useCallback(async () => {
    try {
      const d = await fetchImportDetail(String(job));
      setDetail(d);
      setRows(await fetchImportRows(String(job), filter));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [job, filter]);

  useFocusEffect(useCallback(() => { load(); }, [load]));

  // While the background job works, look again every few seconds.
  useEffect(() => {
    if (timer.current) clearInterval(timer.current);
    if (detail && (detail.status === 'queued' || detail.status === 'processing')) timer.current = setInterval(load, 5000);
    return () => { if (timer.current) clearInterval(timer.current); };
  }, [detail, load]);

  async function run(fn: () => Promise<unknown>) {
    setBusy(true);
    setError('');
    try { await fn(); await load(); } catch (e) { setError(friendlyError(e)); } finally { setBusy(false); }
  }

  if (!detail) return <View style={styles.screen}>{error ? <Notice tone="error">{error}</Notice> : null}</View>;
  const c = detail.counts;
  const preview = detail.status === 'validated';

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.title}>{detail.fileName}</Text>
      <Text style={styles.text}>{`${STATUS_LABELS[detail.status]} · ${detail.totalRows} rows`}</Text>
      <Text style={styles.text}>{`Ready ${c.valid ?? 0} · Needs a fix ${c.invalid ?? 0} · Added ${c.imported ?? 0} · Failed ${c.failed ?? 0} · Skipped ${c.skipped ?? 0}`}</Text>

      {preview ? (
        <>
          <Notice>Fix the rows marked "Needs a fix", or send the file as it is. Rows with errors are skipped, never added.</Notice>
          <Button title={`Send ${c.valid ?? 0} ready row${(c.valid ?? 0) === 1 ? '' : 's'}`} onPress={() => run(() => submitImport(detail.id))} loading={busy} disabled={(c.valid ?? 0) === 0} />
          <Button title="Cancel this import" variant="danger" onPress={() => run(() => cancelImport(detail.id))} />
        </>
      ) : null}
      {detail.status === 'queued' || detail.status === 'processing' ? (
        <>
          <Notice>Your products are being added in the background. You can leave this screen.</Notice>
          {detail.status === 'queued' ? <Button title="Cancel this import" variant="danger" onPress={() => run(() => cancelImport(detail.id))} /> : null}
        </>
      ) : null}
      {isFinished(detail.status) && detail.status !== 'cancelled' && (c.imported ?? 0) > 0 ? (
        <Button title="Go to my listings to add photos and publish" variant="secondary" onPress={() => router.push('/account/listings')} />
      ) : null}
      {canResubmit(detail.status, false) ? (
        <Button
          title="Send the failed rows again"
          onPress={() => run(async () => {
            const next = await resubmitFailed(detail.id);
            router.replace({ pathname: '/business/manage/[id]/imports/[job]', params: { id: String(id), job: next } });
          })}
          loading={busy}
        />
      ) : null}

      <SectionTitle>Rows</SectionTitle>
      <View style={styles.chips}>
        {FILTERS.map((f) => (
          <Chip key={String(f)} label={f ? ROW_LABELS[f] ?? f : 'All'} selected={filter === f} onPress={() => setFilter(f)} />
        ))}
      </View>
      {rows.map((r) => (
        <View key={r.id} style={styles.card}>
          <Text style={styles.name}>{`Row ${r.rowNumber} · ${ROW_LABELS[r.status] ?? r.status}`}</Text>
          <Text style={styles.text}>{`${r.data.sku ?? '(no SKU)'} · ${r.data.title ?? '(no title)'} · K${r.data.price_zmw ?? '?'} · qty ${r.data.quantity ?? '?'}`}</Text>
          {r.errors.map((e, i) => <Text key={`e${i}`} style={styles.err}>{`${e.field}: ${e.message}`}</Text>)}
          {r.warnings.map((w, i) => <Text key={`w${i}`} style={styles.warn}>{w.message}</Text>)}
          {r.failure ? <Text style={styles.err}>{r.failure}</Text> : null}
          {preview && r.status !== 'imported' ? (
            editing === r.id ? (
              <>
                {(['sku', 'title', 'price_zmw', 'quantity', 'category', 'condition'] as const).map((k) => (
                  <Field key={k} label={k} value={draft[k] ?? ''} onChangeText={(v) => setDraft((d) => ({ ...d, [k]: v }))} autoCapitalize="none" />
                ))}
                <Button
                  title="Save fix"
                  loading={busy}
                  onPress={() => run(async () => { await correctImportRow(r.id, draft); setEditing(null); })}
                />
                <Button title="Close" variant="secondary" onPress={() => setEditing(null)} />
              </>
            ) : (
              <Button title="Fix this row" variant="secondary" onPress={() => { setDraft({ ...r.data }); setEditing(r.id); }} />
            )
          ) : null}
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
  name: { fontSize: 16, fontWeight: '700', color: colors.text },
  err: { fontSize: 14, color: colors.danger },
  warn: { fontSize: 14, color: colors.muted },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
});
