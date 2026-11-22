import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../../../src/components/ui';
import { ROLE_EXPLAINED, ROLE_LABELS, emailProblem, roleCan, type BusinessRole } from '../../../../src/domain/business';
import {
  changeMemberRole,
  fetchOpenInvitations,
  fetchTeam,
  inviteMember,
  removeMember,
  revokeInvitation,
  type OpenInvitation,
  type TeamMember,
} from '../../../../src/features/business/api';
import { useBusinessAccess } from '../../../../src/features/business/useAccess';
import { friendlyError } from '../../../../src/lib/errors';
import { colors, radius, spacing } from '../../../../src/theme';

export default function Team() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { userId } = useAuth();
  const { role } = useBusinessAccess(id);
  const [team, setTeam] = useState<TeamMember[]>([]);
  const [invites, setInvites] = useState<OpenInvitation[]>([]);
  const [email, setEmail] = useState('');
  const [inviteRole, setInviteRole] = useState<BusinessRole>('staff');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');

  const isOwner = roleCan(role, 'manage_team');

  const load = useCallback(async () => {
    if (!id) return;
    try {
      setTeam(await fetchTeam(id));
      if (isOwner) setInvites(await fetchOpenInvitations(id));
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [id, isOwner]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  async function run(action: () => Promise<unknown>, done = '') {
    setBusy(true);
    setError('');
    setMessage('');
    try {
      await action();
      setMessage(done);
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  function send() {
    const problem = emailProblem(email);
    if (problem) {
      setError(problem);
      return;
    }
    run(async () => {
      await inviteMember(id!, email, inviteRole);
      setEmail('');
    }, 'Invitation sent. The person sees it when they sign in with that email address.');
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      {message ? <Notice>{message}</Notice> : null}

      <SectionTitle>Team</SectionTitle>
      {team.map((m) => (
        <View key={m.userId} style={styles.card}>
          <Text style={styles.name}>{m.name}{m.userId === userId ? ' (you)' : ''}</Text>
          <Text style={styles.text}>{ROLE_LABELS[m.role]}</Text>
          {isOwner && m.role !== 'owner' ? (
            <>
              <Button
                title={m.role === 'staff' ? 'Make manager' : 'Make staff'}
                variant="secondary"
                disabled={busy}
                onPress={() => run(() => changeMemberRole(id!, m.userId, m.role === 'staff' ? 'manager' : 'staff'))}
              />
              <Button title="Remove from team" variant="danger" disabled={busy} onPress={() => run(() => removeMember(id!, m.userId))} />
            </>
          ) : null}
          {!isOwner && m.userId === userId && m.role !== 'owner' ? (
            <Button title="Leave this business" variant="danger" disabled={busy} onPress={() => run(() => removeMember(id!, m.userId))} />
          ) : null}
        </View>
      ))}

      {isOwner ? (
        <>
          <SectionTitle>Invite someone</SectionTitle>
          <Field label="Their email address" value={email} onChangeText={setEmail} autoCapitalize="none" keyboardType="email-address" />
          <View style={styles.row}>
            <Chip label="Staff" selected={inviteRole === 'staff'} onPress={() => setInviteRole('staff')} />
            <Chip label="Manager" selected={inviteRole === 'manager'} onPress={() => setInviteRole('manager')} />
          </View>
          <Text style={styles.meta}>{ROLE_EXPLAINED[inviteRole]}</Text>
          <Button title="Send invitation" onPress={send} loading={busy} />

          {invites.length > 0 ? <SectionTitle>Waiting for an answer</SectionTitle> : null}
          {invites.map((i) => (
            <View key={i.id} style={styles.card}>
              <Text style={styles.text}>{i.email} as {i.role}</Text>
              <Text style={styles.meta}>Expires {new Date(i.expiresAt).toLocaleDateString()}</Text>
              <Button title="Cancel invitation" variant="secondary" disabled={busy} onPress={() => run(() => revokeInvitation(i.id))} />
            </View>
          ))}
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  row: { flexDirection: 'row', gap: spacing.sm },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  name: { fontSize: 16, fontWeight: '600', color: colors.text },
  text: { fontSize: 14, color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
});
