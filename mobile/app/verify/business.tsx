import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, RequiredLegend, SectionTitle, Star } from '../../src/components/ui';
import { makeSlug, slugProblem, validateBusinessName } from '../../src/domain/trust';
import * as api from '../../src/features/business-onboarding/api';
import {
  BIZ_DECLARATIONS, BIZ_DOC_LABEL, BUSINESS_TYPES, businessStateLine, draftProblems, emptyBizForm, missingBeforeSend, ownershipTotal,
  requiredBusinessDocs, type BizForm, type Party,
} from '../../src/features/business-onboarding/domain';
import { buildBusinessScreen, formFromApplication } from '../../src/features/business-onboarding/view';
import { STATUS_HELP, STATUS_LABEL } from '../../src/features/seller-onboarding/domain';
import { createBusiness, pickOnePhoto } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { singleFlight } from '../../src/lib/singleFlight';
import { colors, radius, spacing } from '../../src/theme';

type Branch = { name: string; address: string; phone: string };
type Permit = { permit_type: string; permit_number: string; issuer: string; expires_on: string };

// Business verification. Creating a business never verifies it: only the owner can apply, and nothing goes live until
// the verification team approves. This screen must never crash and never show an empty page when something failed.
export default function BusinessVerification() {
  const { businessId } = useLocalSearchParams<{ businessId?: string }>();
  if (!businessId) return <CreateBusiness />;
  return <Application businessId={businessId} />;
}

function CreateBusiness() {
  const router = useRouter();
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);

  async function create() {
    if (busyRef.current) return;
    const problem = validateBusinessName(name) ?? slugProblem(makeSlug(name));
    if (problem) {
      setError(problem);
      return;
    }
    busyRef.current = true;
    setBusy(true);
    setError('');
    try {
      const id = await createBusiness(name, makeSlug(name), description);
      router.replace({ pathname: '/verify/business', params: { businessId: id } });
    } catch (e) {
      console.error('[business] creating the business failed', e);
      setError(friendlyError(e));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Notice>Creating a business profile does not make it verified. After this you will send a verification application, and nothing goes live until our team approves it.</Notice>
      <RequiredLegend />
      <Field required label="Business name" value={name} onChangeText={setName} placeholder="Kabulonga Electronics" />
      <Field label="About the business" value={description} onChangeText={setDescription} multiline />
      <Button title="Create the business profile" loading={busy} disabled={busy} onPress={create} />
    </ScrollView>
  );
}

function Application({ businessId }: { businessId: string }) {
  const { userId } = useAuth();
  const [mine, setMine] = useState<api.MyBusinessApplication | null>(null);
  const [form, setForm] = useState<BizForm>(emptyBizForm());
  const [parties, setParties] = useState<Party[]>([]);
  const [branches, setBranches] = useState<Branch[]>([]);
  const [permits, setPermits] = useState<Permit[]>([]);
  const [options, setOptions] = useState<Awaited<ReturnType<typeof api.fetchOptions>> | null>(null);
  const [agreement, setAgreement] = useState<{ version: number; title: string; body: string } | null>(null);
  const [reply, setReply] = useState('');
  const [loading, setLoading] = useState(true);
  const [loadFailed, setLoadFailed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  const dirty = useRef(false); // typed but not saved: a reload must not wipe it
  const busyRef = useRef(false); // a second tap while something runs is ignored

  const loadOnce = useMemo(
    () =>
      singleFlight(async () => {
        setLoading(true);
        try {
          const [m, o, a] = await Promise.all([api.fetchMine(businessId), api.fetchOptions(), api.fetchAgreement()]);
          setMine(m);
          setOptions(o);
          setAgreement(a);
          if (!dirty.current) {
            const saved = formFromApplication(m);
            setForm(saved.form);
            setParties(saved.parties);
            setBranches(m.branches.map((b) => ({ name: b.name, address: b.address, phone: b.phone ?? '' })));
            setPermits(m.permits.map((p) => ({ permit_type: p.permit_type, permit_number: p.permit_number ?? '', issuer: p.issuer ?? '', expires_on: p.expires_on ?? '' })));
          }
          setError('');
          setLoadFailed(false);
          return m;
        } catch (e) {
          console.error('[business] could not load the verification screen', e);
          setError(friendlyError(e));
          setLoadFailed(true);
          return null;
        } finally {
          setLoading(false);
        }
      }),
    [businessId],
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
      console.error('[business] action failed', e);
      setError(friendlyError(e));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };
  const set = <K extends keyof BizForm>(k: K, v: BizForm[K]) => {
    dirty.current = true;
    setForm((f) => ({ ...f, [k]: v }));
  };
  const setParty = (i: number, patch: Partial<Party>) => {
    dirty.current = true;
    setParties((ps) => ps.map((p, j) => (j === i ? { ...p, ...patch } : p)));
  };

  const saveAll = async () => {
    const id = await api.saveApplication(businessId, form);
    await api.setParties(id, parties);
    await api.setBranches(id, branches.filter((b) => b.name.trim() || b.address.trim()).map((b) => ({ name: b.name, address: b.address, phone: b.phone || undefined })));
    await api.setPermits(id, permits.filter((p) => p.permit_type.trim()).map((p) => ({ permit_type: p.permit_type, permit_number: p.permit_number || undefined, issuer: p.issuer || undefined, expires_on: p.expires_on || undefined })));
    dirty.current = false;
  };
  const withValidForm = (action: () => void) => {
    const problems = draftProblems(form, parties);
    if (problems.length > 0) {
      setMessage('');
      setError(problems.join(' '));
      return;
    }
    action();
  };

  if (!mine) {
    if (loading) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
    return (
      <View style={styles.center}>
        <Notice tone="error">{error || 'We could not load your business details.'}</Notice>
        <Button title="Try again" onPress={() => void loadOnce()} />
      </View>
    );
  }

  const model = buildBusinessScreen(mine);
  const app = mine.application;
  const status = model.status;
  const informal = form.route === 'informal_trader';
  const missing = missingBeforeSend(form, parties, { agreementAccepted: !!app?.agreement_accepted, documentKinds: model.documentKinds, contactVerified: true });

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {loading ? <ActivityIndicator color={colors.primary} /> : null}
      {error ? <Notice tone="error">{error}</Notice> : null}
      {loadFailed ? <Button title="Try again" variant="secondary" onPress={() => void loadOnce()} /> : null}
      {message ? <Notice>{message}</Notice> : null}

      <View style={styles.card}>
        <Text style={styles.title}>{model.verified ? (mine.registration_kind === 'informal_trader' ? 'Verified informal trader' : 'Verified registered business') : status ? STATUS_LABEL[status] : 'Not verified'}</Text>
        <Text style={styles.text}>{businessStateLine(mine.publish_state, status)}</Text>
        {status ? <Text style={styles.text}>{STATUS_HELP[status]}</Text> : null}
        {app?.decision_reason && (status === 'rejected' || status === 'suspended' || status === 'revoked') ? <Text style={styles.reason}>{app.decision_reason}</Text> : null}
      </View>

      {model.openRequests.map((r) => (
        <View key={r.id} style={styles.card}>
          <Text style={styles.title}>The team asked</Text>
          <Text style={styles.text}>{r.message}</Text>
          {r.document_kinds.map((k) => (
            <Button key={k} title={`Upload: ${BIZ_DOC_LABEL[k] ?? k}`} variant="secondary" disabled={busy || !userId || !app}
              onPress={() => app && userId && run(() => api.uploadDocument(userId, app.id, k, pickOnePhoto), 'Uploaded. It is checked for safety before anyone sees it.')} />
          ))}
          <Field label="Your answer" value={reply} onChangeText={setReply} multiline />
          <Button title="Send answer" disabled={busy} onPress={() => run(async () => { await api.respondToRequest(r.id, reply); setReply(''); }, 'Answer sent.')} />
        </View>
      ))}

      {model.editable ? (
        <>
          <RequiredLegend />
          <SectionTitle required>Type of business</SectionTitle>
          <View style={styles.chips}>
            <Chip label="Registered business" selected={!informal} onPress={() => { set('route', 'registered'); set('business_type', ''); }} />
            <Chip label="Informal trader (not registered)" selected={informal} onPress={() => { set('route', 'informal_trader'); set('business_type', 'informal_trader'); }} />
          </View>
          {informal ? <Notice>Informal traders are verified through a separate route. You will never be shown as a registered company.</Notice> : (
            <View style={styles.chips}>{BUSINESS_TYPES.map((t) => <Chip key={t.key} label={t.label} selected={form.business_type === t.key} onPress={() => set('business_type', t.key)} />)}</View>
          )}

          <SectionTitle>The business</SectionTitle>
          <Field required label={informal ? 'Your full name' : 'Legal name of the business'} value={form.legal_name} onChangeText={(v) => set('legal_name', v)} />
          <Field label="Trading name (if different)" value={form.trading_name} onChangeText={(v) => set('trading_name', v)} />
          {informal ? (
            <>
              <Field required label="Where you trade (market, stall number)" value={form.trading_place} onChangeText={(v) => set('trading_place', v)} multiline />
              <Field required label="Years of trading" value={form.years_trading} onChangeText={(v) => set('years_trading', v.replace(/\D/g, ''))} keyboardType="number-pad" />
            </>
          ) : (
            <>
              <Field required label="PACRA registration number" value={form.pacra_number} onChangeText={(v) => set('pacra_number', v)} autoCapitalize="characters" />
              <Field required label="Registration date (YYYY-MM-DD)" value={form.pacra_registered_on} onChangeText={(v) => set('pacra_registered_on', v)} placeholder="2018-03-01" />
              <Field required label="TPIN" value={form.tpin} onChangeText={(v) => set('tpin', v)} keyboardType="number-pad" />
            </>
          )}
          <Field required label="Physical address" value={form.physical_address} onChangeText={(v) => set('physical_address', v)} multiline />
          <Field required label="Business phone" value={form.phone} onChangeText={(v) => set('phone', v)} keyboardType="phone-pad" placeholder="+260971000111" />
          <Field required label="Business email" value={form.email} onChangeText={(v) => set('email', v)} keyboardType="email-address" autoCapitalize="none" />

          <SectionTitle required>Where the business is based</SectionTitle>
          <View style={styles.chips}>
            {(options?.locations ?? []).slice(0, 60).map((l) => (
              <Chip key={l.id} label={l.area ? `${l.area}, ${l.town}` : l.town} selected={form.selling_location_id === l.id} onPress={() => set('selling_location_id', l.id)} />
            ))}
          </View>

          <SectionTitle required>What you will sell</SectionTitle>
          <View style={styles.chips}>
            {(options?.categories ?? []).map((c) => (
              <Chip key={c.id} label={c.name} selected={form.category_ids.includes(c.id)}
                onPress={() => set('category_ids', form.category_ids.includes(c.id) ? form.category_ids.filter((x) => x !== c.id) : [...form.category_ids, c.id])} />
            ))}
          </View>
          <Field required label="About how many products will you list?" value={form.expected_catalogue_size} onChangeText={(v) => set('expected_catalogue_size', v.replace(/\D/g, ''))} keyboardType="number-pad" />

          <SectionTitle required>Authorised representative</SectionTitle>
          <Text style={styles.text}>The person applying on behalf of the business. Our team will contact them.</Text>
          <Field required label="Full name" value={form.rep_name} onChangeText={(v) => set('rep_name', v)} />
          <Field required label="Role (for example Managing director)" value={form.rep_role} onChangeText={(v) => set('rep_role', v)} />
          <Field required label="NRC or passport number" value={form.rep_id_number} onChangeText={(v) => set('rep_id_number', v)} />
          <View style={styles.row}><Text style={[styles.text, { flex: 1 }]}>This person is a director or the owner</Text><Switch value={form.rep_is_director} onValueChange={(v) => set('rep_is_director', v)} /></View>
          {!form.rep_is_director ? <Notice>You will need a signed letter from a director giving you authority to act.</Notice> : null}

          {!informal ? (
            <>
              <SectionTitle required>Directors and beneficial owners</SectionTitle>
              <Text style={styles.text}>List at least one director or proprietor. The beneficial owners (the people who really own the business) must add up to 100%. Now: {ownershipTotal(parties)}%.</Text>
              {parties.map((p, i) => (
                <View key={i} style={styles.card}>
                  <View style={styles.chips}>
                    <Chip label="Director" selected={p.kind === 'director'} onPress={() => setParty(i, { kind: 'director' })} />
                    <Chip label="Beneficial owner" selected={p.kind === 'beneficial_owner'} onPress={() => setParty(i, { kind: 'beneficial_owner' })} />
                  </View>
                  <Field required label="Full name" value={p.full_name} onChangeText={(v) => setParty(i, { full_name: v })} />
                  <Field label="Nationality" value={p.nationality} onChangeText={(v) => setParty(i, { nationality: v })} />
                  <Field label="NRC or passport number" value={p.id_number} onChangeText={(v) => setParty(i, { id_number: v })} />
                  {p.kind === 'beneficial_owner' ? <Field required label="Share owned (%)" value={p.ownership_pct} onChangeText={(v) => setParty(i, { ownership_pct: v.replace(/[^0-9.]/g, '') })} keyboardType="decimal-pad" /> : null}
                  <Button title="Remove this person" variant="danger" onPress={() => { dirty.current = true; setParties((ps) => ps.filter((_, j) => j !== i)); }} />
                </View>
              ))}
              <View style={styles.chips}>
                <Button title="Add a director" variant="secondary" onPress={() => { dirty.current = true; setParties((ps) => [...ps, { kind: 'director', full_name: '', nationality: '', ownership_pct: '', id_number: '' }]); }} />
                <Button title="Add a beneficial owner" variant="secondary" onPress={() => { dirty.current = true; setParties((ps) => [...ps, { kind: 'beneficial_owner', full_name: '', nationality: '', ownership_pct: '', id_number: '' }]); }} />
              </View>
            </>
          ) : null}

          <SectionTitle>Branches (optional)</SectionTitle>
          {branches.map((b, i) => (
            <View key={i} style={styles.card}>
              <Field label="Branch name" value={b.name} onChangeText={(v) => { dirty.current = true; setBranches((x) => x.map((y, j) => (j === i ? { ...y, name: v } : y))); }} />
              <Field label="Branch address" value={b.address} onChangeText={(v) => { dirty.current = true; setBranches((x) => x.map((y, j) => (j === i ? { ...y, address: v } : y))); }} />
              <Field label="Branch phone" value={b.phone} onChangeText={(v) => { dirty.current = true; setBranches((x) => x.map((y, j) => (j === i ? { ...y, phone: v } : y))); }} keyboardType="phone-pad" />
              <Button title="Remove branch" variant="danger" onPress={() => { dirty.current = true; setBranches((x) => x.filter((_, j) => j !== i)); }} />
            </View>
          ))}
          <Button title="Add a branch" variant="secondary" onPress={() => { dirty.current = true; setBranches((x) => [...x, { name: '', address: '', phone: '' }]); }} />

          <SectionTitle>Permits and licences (optional)</SectionTitle>
          {permits.map((p, i) => (
            <View key={i} style={styles.card}>
              <Field label="Type of permit" value={p.permit_type} onChangeText={(v) => { dirty.current = true; setPermits((x) => x.map((y, j) => (j === i ? { ...y, permit_type: v } : y))); }} />
              <Field label="Permit number" value={p.permit_number} onChangeText={(v) => { dirty.current = true; setPermits((x) => x.map((y, j) => (j === i ? { ...y, permit_number: v } : y))); }} />
              <Field label="Issued by" value={p.issuer} onChangeText={(v) => { dirty.current = true; setPermits((x) => x.map((y, j) => (j === i ? { ...y, issuer: v } : y))); }} />
              <Field label="Expires (YYYY-MM-DD)" value={p.expires_on} onChangeText={(v) => { dirty.current = true; setPermits((x) => x.map((y, j) => (j === i ? { ...y, expires_on: v } : y))); }} />
              <Button title="Remove permit" variant="danger" onPress={() => { dirty.current = true; setPermits((x) => x.filter((_, j) => j !== i)); }} />
            </View>
          ))}
          <Button title="Add a permit" variant="secondary" onPress={() => { dirty.current = true; setPermits((x) => [...x, { permit_type: '', permit_number: '', issuer: '', expires_on: '' }]); }} />

          <SectionTitle required>Declarations</SectionTitle>
          {BIZ_DECLARATIONS.map((d) => (
            <View key={d.key} style={styles.row}>
              <Text style={[styles.text, { flex: 1 }]}>{d.label}</Text>
              <Switch value={!!form.declarations[d.key]} onValueChange={(v) => set('declarations', { ...form.declarations, [d.key]: v })} />
            </View>
          ))}
          <Button title="Save draft" variant="secondary" loading={busy} disabled={busy} onPress={() => withValidForm(() => void run(saveAll, 'Draft saved.'))} />
        </>
      ) : null}

      {app && model.showDocuments ? (
        <>
          <SectionTitle required>Documents</SectionTitle>
          {requiredBusinessDocs(form.route, form.rep_is_director).map((k) => {
            const d = mine.documents.find((x) => x.kind === k && x.scan !== 'infected');
            return (
              <View key={k} style={styles.card}>
                <Text style={styles.title}>{BIZ_DOC_LABEL[k]}<Star /></Text>
                <Text style={styles.text}>{d ? (d.scan === 'clean' ? 'Uploaded and checked' : 'Uploaded. Being checked for safety') : 'Not uploaded'}</Text>
                <Button title={d ? 'Replace' : 'Upload'} variant="secondary" disabled={busy || !userId}
                  onPress={() => userId && run(() => api.uploadDocument(userId, app.id, k, pickOnePhoto), 'Uploaded.')} />
              </View>
            );
          })}
          <SectionTitle required>Agreement</SectionTitle>
          {agreement ? <Text style={styles.text}>{agreement.body}</Text> : null}
          {app.agreement_accepted ? <Notice>You accepted the agreement.</Notice> : agreement ? (
            <Button title="I accept the agreement" variant="secondary" disabled={busy} onPress={() => run(() => api.acceptAgreement(agreement.version), 'Agreement accepted.')} />
          ) : null}
          {missing.length > 0 ? <Notice tone="warning">Still needed: {missing.join('; ')}.</Notice> : null}
          <Button title="Send application" loading={busy} disabled={missing.length > 0 || busy}
            onPress={() => withValidForm(() => void run(async () => { await saveAll(); await api.submitApplication(app.id); }, 'Sent. We will tell you when it moves.'))} />
          <Button title="Withdraw application" variant="danger" disabled={busy} onPress={() => run(() => api.withdrawApplication(app.id), 'Application withdrawn.')} />
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
