import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { DangerConfirm } from '../../src/components/DangerConfirm';
import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { SELLER_CLOSE } from '../../src/domain/closeAccount';
import { refreshSellingAccess } from '../../src/features/seller/status';
import * as api from '../../src/features/seller-onboarding/api';
import {
  DECLARATIONS, DOC_LABEL, EXPERIENCE, draftProblems, emptyForm, missingBeforeSend, requiredDocs, SOURCING, STATUS_HELP, STATUS_LABEL,
  type Form,
} from '../../src/features/seller-onboarding/domain';
import { buildSellerScreen, formFromApplication } from '../../src/features/seller-onboarding/view';
import { friendlyError } from '../../src/lib/errors';
import { singleFlight } from '../../src/lib/singleFlight';
import { colors, radius, spacing } from '../../src/theme';

// Individual seller application. Anyone can open it; nobody can sell until support approves.
// This screen must never crash and never silently show an empty page when something failed: every request has a loading
// state, an error state with a retry, and an empty state for someone who has never applied.
export default function SellerApplication() {
  const { userId } = useAuth();
  const router = useRouter();
  const [mine, setMine] = useState<api.MyApplication | null>(null);
  const [form, setForm] = useState<Form>(emptyForm());
  const [options, setOptions] = useState<Awaited<ReturnType<typeof api.fetchOptions>> | null>(null);
  const [agreement, setAgreement] = useState<{ version: number; title: string; body: string } | null>(null);
  const [reply, setReply] = useState('');
  const [loading, setLoading] = useState(true);
  const [loadFailed, setLoadFailed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  // Answers typed but not saved yet. A reload (after an upload, say) must not wipe them.
  const dirty = useRef(false);
  // A second tap while something is running is ignored.
  const busyRef = useRef(false);

  // Reopening the screen or pressing "Try again" while a load is running joins that load instead of starting another.
  const loadOnce = useMemo(
    () =>
      singleFlight(async (): Promise<api.MyApplication | null> => {
        setLoading(true);
        try {
          const [m, o, a] = await Promise.all([api.fetchMine(), api.fetchOptions(), api.fetchAgreement()]);
          setMine(m);
          setOptions(o);
          setAgreement(a);
          if (!dirty.current) setForm(formFromApplication(m));
          setError('');
          setLoadFailed(false);
          return m;
        } catch (e) {
          console.error('[seller] could not load the seller screen', e);
          setError(friendlyError(e));
          setLoadFailed(true);
          return null;
        } finally {
          setLoading(false);
        }
      }),
    [],
  );
  useFocusEffect(useCallback(() => { void loadOnce(); }, [loadOnce]));

  const run = async (fn: () => Promise<unknown>, done: string) => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    setError('');
    setMessage('');
    try {
      await fn();
      setMessage(done);
      await loadOnce();
    } catch (e) {
      console.error('[seller] action failed', e);
      setError(friendlyError(e));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };
  const set = <K extends keyof Form>(k: K, v: Form[K]) => {
    dirty.current = true;
    setForm((f) => ({ ...f, [k]: v }));
  };
  // Say which answer is wrong before asking the server, so a draft never fails with a vague message.
  const withValidForm = (action: () => void) => {
    const problems = draftProblems(form);
    if (problems.length > 0) {
      setMessage('');
      setError(problems.join(' '));
      return;
    }
    action();
  };
  const saveForm = async () => {
    await api.saveApplication(form);
    dirty.current = false;
  };

  if (!mine) {
    if (loading) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
    return (
      <View style={styles.center}>
        <Notice tone="error">{error || 'We could not load your seller status.'}</Notice>
        <Button title="Try again" onPress={() => void loadOnce()} />
      </View>
    );
  }

  const model = buildSellerScreen(mine);
  const app = mine.application;
  const status = model.status;
  const missing = missingBeforeSend(form, { agreementAccepted: !!app?.agreement_accepted, documentKinds: model.documentKinds, contactVerified: true });

  async function closeAccount() {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    setError('');
    setMessage('');
    const copy = model.close ?? SELLER_CLOSE;
    try {
      await api.closeSellerAccount();
      if (userId) await refreshSellingAccess(userId);
      // Read back what the database now says, instead of assuming.
      const fresh = await loadOnce();
      if (fresh && fresh.seller_status === 'none') {
        router.replace({ pathname: '/(tabs)/account', params: { notice: 'seller_closed' } });
      } else {
        setMessage(copy.done);
      }
    } catch (e) {
      console.error('[seller] closing the selling account failed', e);
      setError(friendlyError(e));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }

  if (model.mode === 'approved') {
    const copy = model.close ?? SELLER_CLOSE;
    return (
      <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
        {message ? <Notice>{message}</Notice> : null}
        {loadFailed ? <Notice tone="error">{error}</Notice> : null}
        <View style={styles.card}>
          <Text style={styles.title}>You are an approved seller</Text>
          <Text style={styles.text}>Your selling tools are in the Account tab.</Text>
        </View>
        <SectionTitle>{copy.heading}</SectionTitle>
        <DangerConfirm copy={copy} busy={busy} error={loadFailed ? undefined : error} onConfirm={closeAccount} />
      </ScrollView>
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {loading ? <ActivityIndicator color={colors.primary} /> : null}
      {error && !model.close ? <Notice tone="error">{error}</Notice> : null}
      {error && model.close && loadFailed ? <Notice tone="error">{error}</Notice> : null}
      {loadFailed ? <Button title="Try again" variant="secondary" onPress={() => void loadOnce()} /> : null}
      {message ? <Notice>{message}</Notice> : null}
      {model.closedNote ? <Notice>{model.closedNote}</Notice> : null}
      {status ? (
        <View style={styles.card}>
          <Text style={styles.title}>{STATUS_LABEL[status]}</Text>
          <Text style={styles.text}>{STATUS_HELP[status]}</Text>
          {app?.decision_reason && (status === 'rejected' || status === 'suspended' || status === 'revoked') ? <Text style={styles.reason}>{app.decision_reason}</Text> : null}
        </View>
      ) : model.isFirstTime ? (
        <Notice>Buying never needs this. Apply only if you want to sell your own products. Your documents are seen only by our verification team and deleted after the retention period. You have not started an application.</Notice>
      ) : null}

      {model.close ? (
        <>
          <SectionTitle>{model.close.heading}</SectionTitle>
          <DangerConfirm copy={model.close} busy={busy} error={loadFailed ? undefined : error} onConfirm={closeAccount} />
        </>
      ) : null}

      {model.openRequests.map((r) => (
        <View key={r.id} style={styles.card}>
          <Text style={styles.title}>The team asked</Text>
          <Text style={styles.text}>{r.message}</Text>
          {r.document_kinds.map((k) => (
            <Button key={k} title={`Upload: ${DOC_LABEL[k] ?? k}`} variant="secondary" disabled={busy || !userId || !app}
              onPress={() => app && userId && run(() => api.uploadDocument(userId, app.id, k), 'Uploaded. It is checked for safety before anyone sees it.')} />
          ))}
          <Field label="Your answer" value={reply} onChangeText={setReply} multiline />
          <Button title="Send answer" disabled={busy} onPress={() => run(async () => { await api.respondToRequest(r.id, reply); setReply(''); }, 'Answer sent.')} />
        </View>
      ))}

      {model.editable ? (
        <>
          <SectionTitle>About you</SectionTitle>
          <Field label="Full legal name" value={form.legal_name} onChangeText={(v) => set('legal_name', v)} />
          <Field label="Nationality" value={form.nationality} onChangeText={(v) => set('nationality', v)} />
          <View style={styles.row}><Text style={styles.text}>I am 18 or older</Text><Switch value={form.is_adult} onValueChange={(v) => set('is_adult', v)} /></View>
          <View style={styles.chips}>
            <Chip label="NRC" selected={form.id_type === 'nrc'} onPress={() => set('id_type', 'nrc')} />
            <Chip label="Passport" selected={form.id_type === 'passport'} onPress={() => set('id_type', 'passport')} />
          </View>
          <Field label={form.id_type === 'nrc' ? 'NRC number' : 'Passport number'} value={form.id_number} onChangeText={(v) => set('id_number', v)} />
          <Field label="Residential address" value={form.residential_address} onChangeText={(v) => set('residential_address', v)} multiline />

          <SectionTitle>Where you sell from</SectionTitle>
          <View style={styles.chips}>
            {(options?.locations ?? []).slice(0, 60).map((l) => (
              <Chip key={l.id} label={l.area ? `${l.area}, ${l.town}` : l.town} selected={form.selling_location_id === l.id} onPress={() => set('selling_location_id', l.id)} />
            ))}
          </View>

          <SectionTitle>What you will sell</SectionTitle>
          <View style={styles.chips}>
            {(options?.categories ?? []).map((c) => (
              <Chip key={c.id} label={c.name} selected={form.category_ids.includes(c.id)}
                onPress={() => set('category_ids', form.category_ids.includes(c.id) ? form.category_ids.filter((x) => x !== c.id) : [...form.category_ids, c.id])} />
            ))}
          </View>
          <Field label="About how many products will you list?" value={form.expected_catalogue_size} onChangeText={(v) => set('expected_catalogue_size', v.replace(/\D/g, ''))} keyboardType="number-pad" />

          <SectionTitle>Where your products come from</SectionTitle>
          <View style={styles.chips}>{SOURCING.map((s) => <Chip key={s.key} label={s.label} selected={form.sourcing_type === s.key} onPress={() => set('sourcing_type', s.key)} />)}</View>
          <Field label="Tell us more (suppliers, receipts, brands)" value={form.sourcing_info} onChangeText={(v) => set('sourcing_info', v)} multiline />

          <SectionTitle>Experience</SectionTitle>
          <View style={styles.chips}>{EXPERIENCE.map((s) => <Chip key={s.key} label={s.label} selected={form.experience_level === s.key} onPress={() => set('experience_level', s.key)} />)}</View>
          <Field label="Where have you sold before? (optional)" value={form.experience_info} onChangeText={(v) => set('experience_info', v)} multiline />

          <SectionTitle>Customers</SectionTitle>
          <Field label="Returns arrangements" value={form.returns_arrangements} onChangeText={(v) => set('returns_arrangements', v)} multiline />
          <Field label="How you will look after customers" value={form.customer_service_arrangements} onChangeText={(v) => set('customer_service_arrangements', v)} multiline />

          <SectionTitle>Declarations</SectionTitle>
          {DECLARATIONS.map((d) => (
            <View key={d.key} style={styles.row}>
              <Text style={[styles.text, { flex: 1 }]}>{d.label}</Text>
              <Switch value={!!form.declarations[d.key]} onValueChange={(v) => set('declarations', { ...form.declarations, [d.key]: v })} />
            </View>
          ))}
          <Button title="Save draft" variant="secondary" loading={busy} disabled={busy} onPress={() => withValidForm(() => void run(saveForm, 'Draft saved.'))} />
        </>
      ) : null}

      {app && model.showDocuments ? (
        <>
          <SectionTitle>Documents</SectionTitle>
          {requiredDocs(form.id_type).map((k) => {
            const d = mine.documents.find((x) => x.kind === k && x.scan !== 'infected');
            return (
              <View key={k} style={styles.card}>
                <Text style={styles.title}>{DOC_LABEL[k]}</Text>
                <Text style={styles.text}>{d ? (d.scan === 'clean' ? 'Uploaded and checked' : 'Uploaded. Being checked for safety') : 'Not uploaded'}</Text>
                <Button title={d ? 'Replace' : 'Upload'} variant="secondary" disabled={busy || !userId}
                  onPress={() => userId && run(() => api.uploadDocument(userId, app.id, k), 'Uploaded.')} />
              </View>
            );
          })}
          <SectionTitle>Seller agreement</SectionTitle>
          {agreement ? <Text style={styles.text}>{agreement.body}</Text> : null}
          {app.agreement_accepted ? <Notice>You accepted the agreement.</Notice> : agreement ? (
            <Button title="I accept the seller agreement" variant="secondary" disabled={busy} onPress={() => run(() => api.acceptAgreement(agreement.version), 'Agreement accepted.')} />
          ) : null}
          {missing.length > 0 ? <Notice tone="warning">Still needed: {missing.join('; ')}.</Notice> : null}
          <Button title="Send application" loading={busy} disabled={missing.length > 0 || busy}
            onPress={() => withValidForm(() => void run(async () => { await saveForm(); await api.submitApplication(); }, 'Sent. We will tell you when it moves.'))} />
          <Button title="Withdraw application" variant="danger" disabled={busy} onPress={() => run(() => api.withdrawApplication(), 'Application withdrawn.')} />
        </>
      ) : null}

      {mine.history.length > 0 ? (
        <>
          <SectionTitle>History</SectionTitle>
          {mine.history.map((h, i) => <Text key={i} style={styles.text}>{new Date(h.at).toLocaleDateString('en-GB')} · {h.event.replace(/_/g, ' ')}{h.note ? `: ${h.note}` : ''}</Text>)}
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl * 2 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl, gap: spacing.md, backgroundColor: colors.background },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  title: { fontSize: 16, fontWeight: '700', color: colors.text },
  text: { fontSize: 14, color: colors.muted },
  reason: { fontSize: 14, color: colors.text },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.md },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
});
