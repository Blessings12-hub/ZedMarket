import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Linking, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../../src/components/ui';
import * as api from '../../../src/features/business-onboarding/api';
import { BIZ_DOC_LABEL } from '../../../src/features/business-onboarding/domain';
import { openDocument, reviewDocument } from '../../../src/features/seller-onboarding/api';
import { RISK_LABEL, staffActions, STATUS_LABEL, type Action, type AppStatus } from '../../../src/features/seller-onboarding/domain';
import { friendlyError } from '../../../src/lib/errors';
import { singleFlight } from '../../../src/lib/singleFlight';
import { colors, radius, spacing } from '../../../src/theme';

const CHECKS = ['registry_lookup', 'tpin_check', 'phone_call', 'video_call', 'address_check', 'authority_confirmed', 'permit_check', 'other'];

export default function BusinessApplicationReview() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { userId } = useAuth();
  const [d, setD] = useState<Record<string, any> | null>(null);
  const [priv, setPriv] = useState<Awaited<ReturnType<typeof api.fetchPrivate>> | null>(null);
  const [mode, setMode] = useState<Action | 'check' | null>(null);
  const [text, setText] = useState('');
  const [kinds, setKinds] = useState<string[]>([]);
  const [channel, setChannel] = useState('phone');
  const [outcome, setOutcome] = useState('passed');
  const [check, setCheck] = useState('registry_lookup');
  const [checkResult, setCheckResult] = useState('passed');
  const [qa, setQa] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  const busyRef = useRef(false);

  const load = useMemo(
    () => singleFlight(async () => {
      try {
        const r = await api.fetchDetail(id);
        if (!r || typeof r !== 'object') throw new Error('The application came back empty.');
        setD(r);
        setError('');
      } catch (e) {
        console.error('[trust] business application failed to load', e);
        setError(friendlyError(e));
      }
    }),
    [id],
  );
  useFocusEffect(useCallback(() => { void load(); }, [load]));

  const run = async (fn: () => Promise<unknown>, done: string) => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true); setError(''); setMessage('');
    try {
      const r = await fn();
      setMessage(typeof r === 'string' && r.startsWith('awaiting') ? 'Your approval is recorded. A second officer must approve too.' : done);
      setMode(null); setText('');
      await load();
    } catch (e) {
      console.error('[trust] business action failed', e);
      setError(friendlyError(e));
    } finally { busyRef.current = false; setBusy(false); }
  };

  if (!d) {
    return (
      <View style={styles.center}>
        {error ? <><Notice tone="error">{error}</Notice><Button title="Try again" onPress={() => void load()} /></> : <ActivityIndicator color={colors.primary} />}
      </View>
    );
  }

  const status = d.status as AppStatus;
  const actions = staffActions(status, { mine: d.assigned_to === userId, assigned: !!d.assigned_to });
  const mineNow = d.assigned_to === userId;
  const docs: any[] = d.documents ?? [];
  const checks: any[] = d.checks ?? [];
  const parseQa = () => qa.split('\n').map((l) => l.split('|')).filter((p) => p[0]?.trim() && p[1]?.trim()).map((p) => ({ q: (p[0] ?? '').trim(), a: (p[1] ?? '').trim() }));
  const open = async (doc: string) => {
    try { await Linking.openURL(await openDocument(doc)); } catch (e) { setError(friendlyError(e)); }
  };
  const informal = d.route === 'informal_trader';

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {message ? <Notice>{message}</Notice> : null}

      <View style={styles.card}>
        <Text style={styles.title}>{d.business?.name ?? d.legal_name}</Text>
        <Text style={styles.text}>{informal ? 'Informal trader (not a registered company)' : 'Registered business'} · {STATUS_LABEL[status] ?? status} · {RISK_LABEL(d.risk_level ?? 'standard')}</Text>
        <Text style={styles.text}>Legal name: {d.legal_name}{d.trading_name ? ` (trading as ${d.trading_name})` : ''}</Text>
        {informal ? <Text style={styles.text}>Trades at: {d.trading_place} · {d.years_trading} year(s)</Text>
          : <Text style={styles.text}>PACRA {d.pacra_number} · registered {d.pacra_registered_on} · {d.business_type}</Text>}
        <Text style={styles.text}>Address: {d.physical_address}</Text>
        <Text style={styles.text}>Phone {d.phone} · {d.email}</Text>
        <Text style={styles.text}>Catalogue: about {d.expected_catalogue_size} · {(d.categories ?? []).map((c: any) => c.name).join(', ')}</Text>
        <Text style={styles.text}>Representative: {d.rep_name} ({d.rep_role}){d.rep_is_director ? ' — director/owner' : ' — NOT a director, needs a letter of authority'}</Text>
        <Text style={styles.text}>Applicant: {d.applicant?.name} · member since {d.applicant?.member_since ? new Date(d.applicant.member_since).toLocaleDateString('en-GB') : 'unknown'}</Text>
        <Text style={styles.text}>The profile does not verify the business. Establish legitimacy and authority yourself.</Text>
      </View>

      {(d.parties ?? []).length > 0 ? (<>
        <SectionTitle>Directors and beneficial owners</SectionTitle>
        {(d.parties as any[]).map((p, i) => <Text key={i} style={styles.text}>{p.kind === 'director' ? 'Director' : 'Beneficial owner'} · {p.full_name}{p.ownership_pct != null ? ` · ${p.ownership_pct}%` : ''}{p.nationality ? ` · ${p.nationality}` : ''}</Text>)}
      </>) : null}
      {(d.branches ?? []).length > 0 ? (<>
        <SectionTitle>Branches</SectionTitle>
        {(d.branches as any[]).map((b, i) => <Text key={i} style={styles.text}>{b.name} · {b.address}</Text>)}
      </>) : null}
      {(d.permits ?? []).length > 0 ? (<>
        <SectionTitle>Permits</SectionTitle>
        {(d.permits as any[]).map((p, i) => <Text key={i} style={styles.text}>{p.permit_type} {p.permit_number ?? ''} {p.expires_on ? `· expires ${p.expires_on}` : ''}</Text>)}
      </>) : null}

      <SectionTitle>TPIN and ID numbers</SectionTitle>
      {priv ? (
        <View style={styles.card}>
          <Text style={styles.text}>TPIN: {priv.tpin || 'none'}</Text>
          <Text style={styles.text}>Representative ID: {priv.rep_id_number}</Text>
          {(priv.parties ?? []).map((p, i) => <Text key={i} style={styles.text}>{p.full_name}: {p.id_number || 'none'}</Text>)}
        </View>
      ) : (
        <Button title="Show (this is recorded in the audit trail)" variant="secondary" disabled={busy}
          onPress={async () => { try { setPriv((await api.fetchPrivate(id)) ?? null); } catch (e) { setError(friendlyError(e)); } }} />
      )}

      <SectionTitle>Documents (needed: {(d.required_documents ?? []).map((k: string) => BIZ_DOC_LABEL[k] ?? k).join(', ')})</SectionTitle>
      {docs.length === 0 ? <Text style={styles.text}>Nothing uploaded yet.</Text> : null}
      {docs.map((x) => (
        <View key={x.id} style={styles.card}>
          <Text style={styles.title}>{BIZ_DOC_LABEL[x.kind] ?? x.kind}</Text>
          <Text style={styles.text}>Scan: {x.scan} · Review: {x.review}</Text>
          <Button title="Open (audited, link lasts a minute)" variant="secondary" disabled={busy} onPress={() => void open(x.id)} />
          {mineNow ? (
            <View style={styles.row}>
              <Button title="Accept" disabled={busy} onPress={() => run(() => reviewDocument(x.id, true, ''), 'Document accepted.')} />
              <Button title="Reject" variant="danger" disabled={busy || !text.trim()} onPress={() => run(() => reviewDocument(x.id, false, text), 'Document rejected.')} />
            </View>
          ) : null}
        </View>
      ))}
      {mineNow && docs.length > 0 ? <Field label="Note (needed to reject a document)" value={text} onChangeText={setText} /> : null}

      <SectionTitle>Checks (required: {(d.required_checks ?? []).map((c: string) => c.replace(/_/g, ' ')).join(', ')})</SectionTitle>
      {checks.length === 0 ? <Text style={styles.text}>No checks recorded yet.</Text> : checks.map((k, i) => <Text key={i} style={styles.text}>{String(k.type).replace(/_/g, ' ')} · {k.result}{k.notes ? ` · ${k.notes}` : ''}</Text>)}
      {(d.interviews ?? []).length > 0 ? (<><SectionTitle>Interviews</SectionTitle>{(d.interviews as any[]).map((i) => <Text key={i.id} style={styles.text}>{i.channel} · {i.outcome} · {(i.answers ?? []).length} answers recorded</Text>)}</>) : null}

      <SectionTitle>Actions</SectionTitle>
      <View style={styles.chips}>
        {actions.map((x) => x === 'claim'
          ? <Button key={x} title="Claim this application" disabled={busy} onPress={() => run(() => api.claim(id), 'Claimed.')} />
          : <Chip key={x} label={x.replace('_', ' ')} selected={mode === x} onPress={() => setMode(x)} />)}
        {mineNow && status === 'under_review' ? <Chip label="record check" selected={mode === 'check'} onPress={() => setMode('check')} /> : null}
      </View>
      {actions.length === 0 ? <Text style={styles.text}>No action available to you right now.</Text> : null}

      {mode === 'check' ? (<>
        <View style={styles.chips}>{CHECKS.map((c) => <Chip key={c} label={c.replace(/_/g, ' ')} selected={check === c} onPress={() => setCheck(c)} />)}</View>
        <View style={styles.chips}>{['passed', 'failed', 'inconclusive'].map((o) => <Chip key={o} label={o} selected={checkResult === o} onPress={() => setCheckResult(o)} />)}</View>
        <Field label="What you checked and found" value={text} onChangeText={setText} multiline />
        <Button title="Record check" disabled={busy} onPress={() => run(() => api.recordCheck(id, check, checkResult, text), 'Check recorded.')} />
      </>) : null}
      {mode === 'request_info' ? (<>
        <Field label="What do you need from the applicant?" value={text} onChangeText={setText} multiline />
        <View style={styles.chips}>{['director_id', 'authority_letter', 'premises_evidence', 'ownership_evidence', 'other'].map((k) => (
          <Chip key={k} label={BIZ_DOC_LABEL[k] ?? k} selected={kinds.includes(k)} onPress={() => setKinds(kinds.includes(k) ? kinds.filter((z) => z !== k) : [...kinds, k])} />))}</View>
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
      {(d.history ?? []).map((h: any, i: number) => <Text key={i} style={styles.text}>{new Date(h.at).toLocaleString('en-GB')} · {String(h.event).replace(/_/g, ' ')}{h.note ? `: ${h.note}` : ''}</Text>)}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl * 2 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  text: { fontSize: 13, color: colors.muted },
  row: { flexDirection: 'row', gap: spacing.sm },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
});
