import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Field, Notice, SectionTitle } from '../../../src/components/ui';
import { reasonProblem } from '../../../src/domain/admin';
import {
  CHOICE_LABELS,
  PERIOD_CHOICES,
  choiceLabel,
  closesAtFor,
  countsLine,
  formatWhen,
  isDecided,
  outcomeExplanation,
  statusLabel,
  stillNeeded,
  timeLeft,
  type VoteChoice,
} from '../../../src/domain/voting';
import {
  cancelProposal,
  castVote,
  fetchAudit,
  fetchBallots,
  fetchProposal,
  fetchVoteAccess,
  resubmitProposal,
  submitProposal,
  type AuditRow,
  type Ballot,
  type Proposal,
  type VoteAccess,
} from '../../../src/features/voting/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

export default function ProposalScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [p, setP] = useState<Proposal | null>(null);
  const [access, setAccess] = useState<VoteAccess | null>(null);
  const [missing, setMissing] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);
  const [choice, setChoice] = useState<VoteChoice | null>(null);
  const [hours, setHours] = useState(72);
  const [cancelling, setCancelling] = useState(false);
  const [reason, setReason] = useState('');
  const [ballots, setBallots] = useState<Ballot[] | null>(null);
  const [audit, setAudit] = useState<{ rows: AuditRow[]; intact: boolean } | null>(null);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const [proposal, a] = await Promise.all([fetchProposal(id), fetchVoteAccess()]);
      setP(proposal);
      setMissing(!proposal);
      setAccess(a);
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [id]);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError('');
    setNotice('');
    try {
      await action();
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!p) {
    return (
      <View style={styles.center}>
        {error ? <Notice tone="error">{error}</Notice> : missing ? <Text style={styles.text}>This proposal was not found.</Text> : <ActivityIndicator color={colors.primary} />}
      </View>
    );
  }

  const tally = { for: p.forCount, against: p.againstCount, abstain: p.abstainCount, hidden: p.countsHidden };
  const need = stillNeeded(tally, p.requiredVotes);
  const decided = isDecided(p.status);
  const canSeeBallots = !!access?.canAudit && decided && !p.confidential;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {notice ? <Notice>{notice}</Notice> : null}

      <Text style={styles.ref}>{p.reference} · {statusLabel(p.status)}{p.confidential ? ' · Confidential' : ''}</Text>
      <Text style={styles.title}>{p.title}</Text>
      <Text style={styles.meta}>Proposed by {p.proposerName} on {formatWhen(p.createdAt)}</Text>
      {p.resubmittedFrom ? <Text style={styles.meta}>Resubmitted after an unresolved vote.</Text> : null}
      {p.resubmittedAs ? (
        <Button title="Open the resubmitted proposal" variant="secondary" onPress={() => router.push(`/admin/votes/${p.resubmittedAs}`)} />
      ) : null}

      <SectionTitle>What is being decided</SectionTitle>
      <Text style={styles.text}>{p.description}</Text>
      <SectionTitle>Why</SectionTitle>
      <Text style={styles.text}>{p.reason}</Text>

      {p.status !== 'draft' ? (
        <>
          <SectionTitle>Voting</SectionTitle>
          <View style={styles.box}>
            <Text style={styles.meta}>Opens {formatWhen(p.opensAt)}</Text>
            <Text style={styles.meta}>Closes {formatWhen(p.closesAt)}{p.status === 'active' ? ` (${timeLeft(p.closesAt)})` : ''}</Text>
            {p.eligibleCount !== null ? (
              <Text style={styles.meta}>
                {p.eligibleCount} eligible staff. {p.requiredVotes} votes (two thirds) are needed to approve or to reject.
              </Text>
            ) : null}
            <Text style={styles.counts}>{countsLine(tally)}</Text>
            {p.status === 'active' && p.votedCount !== null && !p.countsHidden ? (
              <Text style={styles.meta}>{p.votedCount} of {p.eligibleCount} have voted.</Text>
            ) : null}
            {need && p.status === 'active' ? (
              <Text style={styles.meta}>To pass: {need.forNeeds} more FOR. To reject: {need.againstNeeds} more AGAINST.</Text>
            ) : null}
            {p.myChoice ? <Text style={styles.meta}>Your vote: {choiceLabel(p.myChoice)}</Text> : null}
          </View>
          {outcomeExplanation(p.status, p.requiredVotes, p.eligibleCount) ? (
            <Notice tone={p.status === 'cancelled' ? 'warning' : 'info'}>{outcomeExplanation(p.status, p.requiredVotes, p.eligibleCount)}</Notice>
          ) : null}
          {p.cancelReason ? <Text style={styles.meta}>Reason: {p.cancelReason}</Text> : null}
        </>
      ) : null}

      {p.canVote ? (
        <>
          <SectionTitle>Cast your vote</SectionTitle>
          <Text style={styles.text}>You can vote once. It cannot be changed afterwards.</Text>
          <View style={styles.chips}>
            {(Object.keys(CHOICE_LABELS) as VoteChoice[]).map((c) => (
              <Chip key={c} label={CHOICE_LABELS[c]} selected={choice === c} onPress={() => setChoice(c)} />
            ))}
          </View>
          <Button
            title={choice ? `Confirm: vote ${CHOICE_LABELS[choice].toLowerCase()}` : 'Choose how to vote'}
            disabled={!choice}
            loading={busy}
            onPress={() =>
              run(async () => {
                if (!choice) return;
                const status = await castVote(p.id, choice);
                setChoice(null);
                setNotice(status === 'active' ? 'Your vote was recorded.' : `Your vote was recorded and it decided this proposal: ${statusLabel(status).toLowerCase()}.`);
              })
            }
          />
        </>
      ) : null}

      {p.status === 'draft' && p.iAmProposer ? (
        <>
          <SectionTitle>Open the vote</SectionTitle>
          <Text style={styles.text}>Voting opens now and the list of eligible staff is fixed at that moment. How long should it stay open?</Text>
          <View style={styles.chips}>
            {PERIOD_CHOICES.map((c) => (
              <Chip key={c.hours} label={c.label} selected={hours === c.hours} onPress={() => setHours(c.hours)} />
            ))}
          </View>
          <Button
            title="Open the vote now"
            loading={busy}
            onPress={() =>
              run(async () => {
                await submitProposal(p.id, null, closesAtFor(hours));
                setNotice('The vote is open and eligible staff have been told.');
              })
            }
          />
        </>
      ) : null}

      {p.status === 'unresolved' && (p.iAmProposer || access?.canAudit) && !p.resubmittedAs ? (
        <Button
          title="Resubmit as a new proposal"
          variant="secondary"
          loading={busy}
          onPress={() =>
            run(async () => {
              const newId = await resubmitProposal(p.id);
              router.replace(`/admin/votes/${newId}`);
            })
          }
        />
      ) : null}

      {(p.status === 'draft' || p.status === 'pending') && (p.iAmProposer || access?.canAudit) ? (
        <CancelBlock open={cancelling} setOpen={setCancelling} reason={reason} setReason={setReason} busy={busy}
          onConfirm={() => run(async () => { await cancelProposal(p.id, reason.trim()); setCancelling(false); setReason(''); })} />
      ) : null}
      {p.status === 'active' && access?.canAudit && !p.iAmProposer ? (
        <CancelBlock open={cancelling} setOpen={setCancelling} reason={reason} setReason={setReason} busy={busy}
          onConfirm={() => run(async () => { await cancelProposal(p.id, reason.trim()); setCancelling(false); setReason(''); })} />
      ) : null}

      {canSeeBallots ? (
        <>
          <SectionTitle>Individual votes (technical admin)</SectionTitle>
          <Text style={styles.meta}>Opening this is recorded in the audit trail.</Text>
          {ballots === null ? (
            <Button title="Show individual votes" variant="secondary" loading={busy} onPress={() => run(async () => setBallots(await fetchBallots(p.id)))} />
          ) : (
            ballots.map((b) => (
              <Text key={b.voterId} style={styles.text}>{b.voterName}: {choiceLabel(b.choice)}</Text>
            ))
          )}
        </>
      ) : null}

      {access?.canAudit && p.status !== 'draft' ? (
        <>
          <SectionTitle>Audit trail (technical admin)</SectionTitle>
          {audit === null ? (
            <Button title="Show audit trail" variant="secondary" loading={busy} onPress={() => run(async () => setAudit(await fetchAudit(p.id)))} />
          ) : (
            <>
              <Notice tone={audit.intact ? 'info' : 'error'}>
                {audit.intact ? 'The audit trail is intact.' : 'The audit trail does not match its checksums. Something was changed.'}
              </Notice>
              {audit.rows.map((r) => (
                <Text key={r.seq} style={styles.meta}>
                  {r.seq}. {formatWhen(r.createdAt)} · {r.action.replace(/_/g, ' ')}{r.actorName ? ` · ${r.actorName}` : ''}
                </Text>
              ))}
            </>
          )}
        </>
      ) : null}
    </ScrollView>
  );
}

function CancelBlock(props: { open: boolean; setOpen: (v: boolean) => void; reason: string; setReason: (v: string) => void; busy: boolean; onConfirm: () => void }) {
  const problem = props.reason ? reasonProblem(props.reason) : null;
  if (!props.open) return <Button title="Cancel this proposal" variant="danger" onPress={() => props.setOpen(true)} />;
  return (
    <View style={styles.box}>
      <Field label="Reason for cancelling (saved in the audit trail)" value={props.reason} onChangeText={props.setReason} error={problem ?? undefined} maxLength={500} />
      <Button title="Yes, cancel it" variant="danger" loading={props.busy} disabled={!props.reason || !!problem} onPress={props.onConfirm} />
      <Button title="Keep it" variant="secondary" disabled={props.busy} onPress={() => props.setOpen(false)} />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, padding: spacing.xl, justifyContent: 'center', backgroundColor: colors.background },
  ref: { fontSize: 13, fontWeight: '600', color: colors.muted },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.text },
  meta: { fontSize: 14, lineHeight: 20, color: colors.muted },
  counts: { fontSize: 16, fontWeight: '700', color: colors.text },
  box: { gap: spacing.sm, padding: spacing.md, borderRadius: radius.md, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
});
