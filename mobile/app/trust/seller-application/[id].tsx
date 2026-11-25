import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Linking, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../../src/components/ui';
import * as api from '../../../src/features/seller-onboarding/api';
import { DOC_LABEL, RISK_LABEL, staffActions, STATUS_LABEL, type Action, type AppStatus } from '../../../src/features/seller-onboarding/domain';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

export default function SellerApplicationReview() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { userId } = useAuth();
  const [d, setD] = useState<Record<string, any> | null>(null);
  const [priv, setPriv] = useState<{ id_number: string; residential_address: string } | null>(null);
  const [mode, setMode] = useState<Action | null>(null);
  const [text, setText] = useState('');
  const [kinds, setKinds] = useState<string[]>([]);
  const [channel, setChannel] = useState('phone');
  const [outcome, setOutcome] = useState('passed');
  const [qa, setQa] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');

  const load = useCallback(async () => {
    try { setD(await api.fetchDetail(id)); setError(''); } catch (e) { setError(friendlyError(e)); }
  }, [id]);
  useFocusEffect(useCallback(() => { load(); }, [load]));

  const run = async (fn: () => Promise<unknown>, done: string) => {
    setBusy(true); setError(''); setMessage('');
    try { const r = await fn(); setMessage(typeof r === 'string' && r.startsWith('awaiting') ? 'Your approval is recorded. A second officer must approve too.' : done); setMode(null); setText(''); await load(); }
    catch (e) { setError(friendlyError(e)); } finally { setBusy(false); }
  };

  if (!d) return <View style={styles.center}>{error ? <Notice tone="error">{error}</Notice> : <ActivityIndicator color={colors.primary} />}</View>;

  const a = d.application ?? d;
  const status = a.status as AppStatus;
  const actions = staffActions(status, { mine: a.assigned_to === userId, assigned: !!a.assigned_to });
  const docs: any[] = d.documents ?? [];
  const parseQa = () => qa.split('\n').map((l) => l.split('|')).filter((p) => p[0]?.trim() && p[1]?.trim()).map((p) => ({ q: (p[0] ?? '').trim(), a: (p[1] ?? '').trim() }));

  const open = async (doc: string) => {
    try { await Linking.openURL(await api.openDocument(doc)); } catch (e) { setError(friendlyError(e)); }
  };

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {message ? <Notice>{message}</Notice> : null}
      <View style={styles.card}>
        <Text style={styles.title}>{a.legal_name ?? 'Applicant'}</Text>
        <Text style={styles.text}>{STATUS_LABEL[status]} · {RISK_LABEL(a.risk_level ?? 'standard')}</Text>
        <Text style={styles.text}>Nationality: {a.nationality} · ID type: {a.id_type}</Text>
        <Text style={styles.text}>Catalogue: about {a.expected_catalogue_size} · Experience: {a.experience_level}</Text>
        <Text style={styles.text}>Sourcing ({a.sourcing_type}): {a.sourcing_info}</Text>
        <Text style={styles.text}>Returns: {a.returns_arrangements}</Text>
        <Text style={styles.text}>Customer care: {a.customer_service_arrangements}</Text>
      </View>

      <SectionTitle>ID number and address</SectionTitle>
      {priv ? (
        <View style={styles.card}><Text style={styles.text}>ID: {priv.id_number}</Text><Text style={styles.text}>Address: {priv.residential_address}</Text></View>
      ) : (
        <Button title="Show (this is recorded in the audit trail)" variant="secondary" disabled={busy}
          onPress={async () => { try { setPriv((await api.fetchPrivate(id)) ?? null); } catch (e) { setError(friendlyError(e)); } }} />
      )}

      <SectionTitle>Documents</SectionTitle>
      {docs.map((x) => (
        <View key={x.id} style={styles.card}>
          <Text style={styles.title}>{DOC_LABEL[x.kind] ?? x.kind}</Text>
          <Text style={styles.text}>Scan: {x.scan_status ?? x.scan} · Review: {x.review_status ?? x.review}</Text>
          <Button title="Open (audited, link lasts a minute)" variant="secondary" disabled={busy} onPress={() => open(x.id)} />
          {a.assigned_to === userId ? (
            <View style={styles.row}>
              <Button title="Accept" disabled={busy} onPress={() => run(() => api.reviewDocument(x.id, true, ''), 'Document accepted.')} />
              <Button title="Reject" variant="danger" disabled={busy || !text.trim()} onPress={() => run(() => api.reviewDocument(x.id, false, text), 'Document rejected.')} />
            </View>
          ) : null}
        </View>
      ))}
      {a.assigned_to === userId && docs.length > 0 ? <Field label="Note (needed to reject a document)" value={text} onChangeText={setText} /> : null}

      {(d.interviews ?? []).length > 0 ? (<><SectionTitle>Interviews</SectionTitle>{(d.interviews as any[]).map((i) => <Text key={i.id} style={styles.text}>{i.channel} · {i.outcome} · {(i.answers ?? []).length} answers recorded</Text>)}</>) : null}

      <SectionTitle>Actions</SectionTitle>
      <View style={styles.chips}>
        {actions.map((x) => x === 'claim'
          ? <Button key={x} title="Claim this application" disabled={busy} onPress={() => run(() => api.claim(id), 'Claimed.')} />
          : <Chip key={x} label={x.replace('_', ' ')} selected={mode === x} onPress={() => setMode(x)} />)}
      </View>
      {actions.length === 0 ? <Text style={styles.text}>No action available to you right now.</Text> : null}

      {mode === 'request_info' ? (<>
        <Field label="What do you need from the applicant?" value={text} onChangeText={setText} multiline />
        <View style={styles.chips}>{['sourcing_evidence', 'product_evidence', 'proof_of_address', 'other'].map((k) => (
          <Chip key={k} label={DOC_LABEL[k] ?? k} selected={kinds.includes(k)} onPress={() => setKinds(kinds.includes(k) ? kinds.filter((z) => z !== k) : [...kinds, k])} />))}</View>
        <Button title="Send request" disabled={busy} onPress={() => run(() => api.requestInfo(id, text, kinds), 'Request sent.')} />
      </>) : null}
      {mode === 'interview' ? (<>
        <View style={styles.chips}>{['phone', 'video'].map((c) => <Chip key={c} label={c} selected={channel === c} onPress={() => setChannel(c)} />)}
          {['passed', 'failed', 'inconclusive'].map((o) => <Chip key={o} label={o} selected={outcome === o} onPress={() => setOutcome(o)} />)}</View>
        <Field label="Questions and answers, one per line: question | answer" value={qa} onChangeText={setQa} multiline />
        <Field label="Notes" value={text} onChangeText={setText} multiline />
        <Button title="Record interview" disabled={busy} onPress={() => run(() => api.recordInterview(id, channel, outcome, parseQa(), text), 'Interview recorded.')} />
      </>) : null}
      {mode === 'escalate' ? (<><Field label="Why is this being escalated?" value={text} onChangeText={setText} multiline /><Button title="Escalate" disabled={busy} onPress={() => run(() => api.escalate(id, text), 'Escalated.')} /></>) : null}
      {mode === 'approve' || mode === 'reject' ? (<><Field label={mode === 'approve' ? 'Reason for approving' : 'Reason (the applicant will read this)'} value={text} onChangeText={setText} multiline />
        <Button title={mode === 'approve' ? 'Approve' : 'Reject'} variant={mode === 'reject' ? 'danger' : 'primary'} disabled={busy} onPress={() => run(() => api.decide(id, mode === 'approve' ? 'approve' : 'reject', text), mode === 'approve' ? 'Approved.' : 'Rejected.')} /></>) : null}
      {mode === 'suspend' ? (<><Field label="Reason" value={text} onChangeText={setText} multiline />
        <Button title="Suspend selling" variant="danger" disabled={busy} onPress={() => run(() => api.suspend(id, text, false), 'Suspended. Listings paused, history kept.')} />
        <Button title="Revoke approval" variant="danger" disabled={busy} onPress={() => run(() => api.suspend(id, text, true), 'Revoked.')} /></>) : null}
      {mode === 'reinstate' ? (<><Field label="Reason (a different officer from the one who suspended)" value={text} onChangeText={setText} multiline />
        <Button title="Reinstate" disabled={busy} onPress={() => run(() => api.reinstate(id, text), 'Reinstated.')} /></>) : null}

      <SectionTitle>History</SectionTitle>
      {(d.history ?? []).map((h: any, i: number) => <Text key={i} style={styles.text}>{new Date(h.at).toLocaleString('en-GB')} · {h.event.replace(/_/g, ' ')}{h.note ? `: ${h.note}` : ''}</Text>)}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl * 2 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  text: { fontSize: 13, color: colors.muted },
  row: { flexDirection: 'row', gap: spacing.sm },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
});
