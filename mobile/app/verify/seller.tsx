import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import * as api from '../../src/features/seller-onboarding/api';
import {
  canEdit, DECLARATIONS, DOC_LABEL, EXPERIENCE, emptyForm, missingBeforeSend, requiredDocs, SOURCING, STATUS_HELP, STATUS_LABEL,
  type AppStatus, type Form,
} from '../../src/features/seller-onboarding/domain';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

// Individual seller application. Anyone can open it; nobody can sell until support approves.
export default function SellerApplication() {
  const { userId } = useAuth();
  const [mine, setMine] = useState<api.MyApplication | null>(null);
  const [form, setForm] = useState<Form>(emptyForm());
  const [options, setOptions] = useState<Awaited<ReturnType<typeof api.fetchOptions>> | null>(null);
  const [agreement, setAgreement] = useState<{ version: number; title: string; body: string } | null>(null);
  const [reply, setReply] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');

  const load = useCallback(async () => {
    try {
      const [m, o, a] = await Promise.all([api.fetchMine(), api.fetchOptions(), api.fetchAgreement()]);
      setMine(m);
      setOptions(o);
      setAgreement(a ?? null);
      const x = m.application;
      if (x) {
        setForm({
          ...emptyForm(), legal_name: x.legal_name ?? '', nationality: x.nationality ?? '', is_adult: !!x.is_adult, id_type: x.id_type ?? 'nrc',
          id_number: x.id_number ?? '', residential_address: x.residential_address ?? '', selling_location_id: x.selling_location_id ?? null,
          category_ids: x.category_ids ?? [], sourcing_type: x.sourcing_type ?? '', sourcing_info: x.sourcing_info ?? '',
          experience_level: x.experience_level ?? '', experience_info: x.experience_info ?? '',
          expected_catalogue_size: x.expected_catalogue_size ? String(x.expected_catalogue_size) : '', returns_arrangements: x.returns_arrangements ?? '',
          customer_service_arrangements: x.customer_service_arrangements ?? '', declarations: x.declarations ?? {},
        });
      }
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, []);
  useFocusEffect(useCallback(() => { load(); }, [load]));

  const run = async (fn: () => Promise<unknown>, done: string) => {
    setBusy(true);
    setError('');
    setMessage('');
    try {
      await fn();
      setMessage(done);
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  };
  const set = <K extends keyof Form>(k: K, v: Form[K]) => setForm((f) => ({ ...f, [k]: v }));

  if (!mine && !error) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  if (!mine) return <View style={styles.center}><Notice tone="error">{error}</Notice></View>;

  const app = mine.application;
  const status = (app?.status ?? null) as AppStatus | null;
  const editable = canEdit(status) && mine.seller_status === 'none';
  const kinds = mine.documents.filter((d) => d.scan !== 'infected').map((d) => d.kind);
  const missing = missingBeforeSend(form, { agreementAccepted: !!app?.agreement_accepted, documentKinds: kinds, contactVerified: true });
  const openRequests = mine.requests.filter((r) => r.status === 'open');

  if (mine.seller_status === 'active') {
    return <View style={styles.center}><Text style={styles.title}>You are an approved seller</Text><Text style={styles.text}>Your selling tools are in the Account tab.</Text></View>;
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {message ? <Notice>{message}</Notice> : null}
      {status ? (
        <View style={styles.card}>
          <Text style={styles.title}>{STATUS_LABEL[status]}</Text>
          <Text style={styles.text}>{STATUS_HELP[status]}</Text>
          {app?.decision_reason && (status === 'rejected' || status === 'suspended' || status === 'revoked') ? <Text style={styles.reason}>{app.decision_reason}</Text> : null}
        </View>
      ) : (
        <Notice>Buying never needs this. Apply only if you want to sell your own products. Your documents are seen only by our verification team and deleted after the retention period.</Notice>
      )}

      {openRequests.map((r) => (
        <View key={r.id} style={styles.card}>
          <Text style={styles.title}>The team asked</Text>
          <Text style={styles.text}>{r.message}</Text>
          {r.document_kinds.map((k) => (
            <Button key={k} title={`Upload: ${DOC_LABEL[k] ?? k}`} variant="secondary" disabled={busy}
              onPress={() => run(() => api.uploadDocument(userId!, app!.id, k), 'Uploaded. It is checked for safety before anyone sees it.')} />
          ))}
          <Field label="Your answer" value={reply} onChangeText={setReply} multiline />
          <Button title="Send answer" disabled={busy} onPress={() => run(async () => { await api.respondToRequest(r.id, reply); setReply(''); }, 'Answer sent.')} />
        </View>
      ))}

      {editable ? (
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
              <Chip key={l.id} label={`${l.area}, ${l.city}`} selected={form.selling_location_id === l.id} onPress={() => set('selling_location_id', l.id)} />
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
          <Button title="Save draft" variant="secondary" loading={busy} onPress={() => run(() => api.saveApplication(form), 'Draft saved.')} />
        </>
      ) : null}

      {app && editable ? (
        <>
          <SectionTitle>Documents</SectionTitle>
          {requiredDocs(form.id_type).map((k) => {
            const d = mine.documents.find((x) => x.kind === k && x.scan !== 'infected');
            return (
              <View key={k} style={styles.card}>
                <Text style={styles.title}>{DOC_LABEL[k]}</Text>
                <Text style={styles.text}>{d ? (d.scan === 'clean' ? 'Uploaded and checked' : 'Uploaded. Being checked for safety') : 'Not uploaded'}</Text>
                <Button title={d ? 'Replace' : 'Upload'} variant="secondary" disabled={busy}
                  onPress={() => run(() => api.uploadDocument(userId!, app.id, k), 'Uploaded.')} />
              </View>
            );
          })}
          <SectionTitle>Seller agreement</SectionTitle>
          {agreement ? <Text style={styles.text}>{agreement.body}</Text> : null}
          {app.agreement_accepted ? <Notice>You accepted the agreement.</Notice> : agreement ? (
            <Button title="I accept the seller agreement" variant="secondary" disabled={busy} onPress={() => run(() => api.acceptAgreement(agreement.version), 'Agreement accepted.')} />
          ) : null}
          {missing.length > 0 ? <Notice tone="warning">Still needed: {missing.join('; ')}.</Notice> : null}
          <Button title="Send application" loading={busy} disabled={missing.length > 0 || busy} onPress={() => run(async () => { await api.saveApplication(form); await api.submitApplication(); }, 'Sent. We will tell you when it moves.')} />
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
