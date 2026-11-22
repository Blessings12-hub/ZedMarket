import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../../src/auth/AuthProvider';
import { Button, Field, Notice, SectionTitle, VerifiedBadge } from '../../../src/components/ui';
import { canChangeAccountState, reasonProblem, type AdminRole } from '../../../src/domain/admin';
import { STATUS_LABELS, nextAccountStates, stateActionLabel } from '../../../src/domain/trustAdmin';
import { fetchMyRoles, type AccountState } from '../../../src/features/admin/api';
import {
  changeAccountState,
  fetchTrustProfile,
  fetchVerificationHistory,
  type Application,
  type TrustProfile,
} from '../../../src/features/trust-admin/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

export default function TrustUserProfile() {
  const router = useRouter();
  const { userId: me } = useAuth();
  const { id } = useLocalSearchParams<{ id: string }>();
  const [profile, setProfile] = useState<TrustProfile | null>(null);
  const [history, setHistory] = useState<Application[]>([]);
  const [roles, setRoles] = useState<AdminRole[]>([]);
  const [target, setTarget] = useState<AccountState | null>(null);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const [p, h, r] = await Promise.all([fetchTrustProfile(id), fetchVerificationHistory(id), me ? fetchMyRoles(me) : Promise.resolve([] as AdminRole[])]);
      setProfile(p);
      setHistory(h);
      setRoles(r);
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [id, me]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  async function applyState() {
    if (!profile || !target) return;
    const problem = reasonProblem(reason);
    if (problem) {
      setError(problem);
      return;
    }
    setBusy(true);
    setError('');
    try {
      await changeAccountState(profile.id, target, reason);
      setTarget(null);
      setReason('');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!profile) {
    return (
      <View style={styles.screen}>
        <View style={{ padding: spacing.lg }}>{error ? <Notice tone="error">{error}</Notice> : <Text style={styles.meta}>Loading…</Text>}</View>
      </View>
    );
  }

  const mayChangeState = canChangeAccountState(roles) && profile.id !== me;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <View style={styles.row}>
        <Text style={styles.title}>{profile.displayName}</Text>
        <VerifiedBadge level={profile.verificationLevel} />
      </View>
      <Text style={styles.meta}>Joined {new Date(profile.joinedAt).toLocaleDateString()}</Text>
      {profile.bio ? <Text style={styles.text}>{profile.bio}</Text> : null}
      {profile.staffRoles.length > 0 ? <Notice>Staff member: {profile.staffRoles.join(', ')}</Notice> : null}

      <SectionTitle>Account</SectionTitle>
      <View style={styles.card}>
        <Text style={styles.text}>
          State: {profile.accountState === 'active' ? 'Active' : profile.accountState === 'suspended' ? 'Suspended' : 'Restricted'}
        </Text>
        {profile.stateReason ? <Text style={styles.meta}>Reason: {profile.stateReason}</Text> : null}
        {profile.stateChangedAt ? <Text style={styles.meta}>Since {new Date(profile.stateChangedAt).toLocaleString()}</Text> : null}
      </View>

      {mayChangeState ? (
        target ? (
          <>
            <Field
              label={`Why ${stateActionLabel(target).toLowerCase()}? This is saved in the audit trail.`}
              value={reason}
              onChangeText={setReason}
              multiline
              maxLength={500}
              style={{ minHeight: 80, textAlignVertical: 'top' }}
            />
            <Button title={`Confirm: ${stateActionLabel(target)}`} variant={target === 'active' ? 'primary' : 'danger'} onPress={applyState} loading={busy} />
            <Button title="Back" variant="secondary" onPress={() => setTarget(null)} disabled={busy} />
          </>
        ) : (
          nextAccountStates(profile.accountState).map((s) => (
            <Button
              key={s}
              title={stateActionLabel(s)}
              variant="secondary"
              onPress={() => {
                setTarget(s);
                setReason('');
                setError('');
              }}
            />
          ))
        )
      ) : null}

      <SectionTitle>Activity</SectionTitle>
      <View style={styles.card}>
        <Text style={styles.text}>Listings: {profile.listingsTotal} ({profile.listingsActive} active)</Text>
        <Text style={styles.text}>Orders as buyer: {profile.ordersAsBuyer} · as seller: {profile.ordersAsSeller}</Text>
        <Text style={styles.text}>Completed orders: {profile.ordersCompleted}</Text>
        <Text style={styles.text}>Disputes opened: {profile.disputesOpened}</Text>
        <Text style={styles.text}>
          Reports against this person: {profile.reportsAgainst} ({profile.reportsOpenAgainst} open)
        </Text>
      </View>

      {profile.businesses.length > 0 ? (
        <>
          <SectionTitle>Businesses</SectionTitle>
          {profile.businesses.map((b) => (
            <View key={b.id} style={styles.card}>
              <Text style={styles.text}>{b.name}</Text>
              <Text style={styles.meta}>Verification: {b.verificationStatus}</Text>
            </View>
          ))}
        </>
      ) : null}

      <SectionTitle>Verification history</SectionTitle>
      {history.length === 0 ? <Text style={styles.meta}>No applications yet.</Text> : null}
      {history.map((h) => (
        <View key={`${h.kind}-${h.id}`} style={styles.card}>
          <Text style={styles.text}>
            {h.kind === 'identity' ? 'Identity' : 'Business'}: {h.subjectName} ({h.detail}) — {STATUS_LABELS[h.status]}
          </Text>
          <Text style={styles.meta}>Sent {new Date(h.submittedAt).toLocaleString()}</Text>
          {h.reviewedAt ? (
            <Text style={styles.meta}>
              Decided {new Date(h.reviewedAt).toLocaleString()} by {h.reviewerName ?? 'unknown'}
              {h.reviewerNote ? ` — ${h.reviewerNote}` : ''}
            </Text>
          ) : null}
        </View>
      ))}

      <SectionTitle>Audit trail</SectionTitle>
      <Button title="Everything staff did about this person" variant="secondary" onPress={() => router.push({ pathname: '/trust/audit', params: { userId: profile.id } })} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  row: { flexDirection: 'row', gap: spacing.sm, alignItems: 'center', flexWrap: 'wrap' },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 4 },
});
