import { useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../../src/auth/AuthProvider';
import { Button, Field, Notice, SectionTitle } from '../../../src/components/ui';
import { canHandleReports, canModerate, reasonProblem, type AdminRole } from '../../../src/domain/admin';
import { formatKwacha } from '../../../src/domain/money';
import {
  changeAccountState,
  fetchAccount,
  fetchMessageSender,
  fetchMyRoles,
  fetchReport,
  readReportedConversation,
  fetchReviewForStaff,
  removeListing,
  resolveReport,
  setReviewHidden,
  type AccountState,
  type AccountSummary,
  type ReportRow,
  type ReportStatus,
  type ReportedReview,
} from '../../../src/features/admin/api';
import type { Message } from '../../../src/features/chat/api';
import { fetchListing } from '../../../src/features/listings/api';
import type { ListingDetail } from '../../../src/features/listings/types';
import { REPORT_REASONS } from '../../../src/features/reports/api';
import { friendlyError } from '../../../src/lib/errors';
import { listingImageUrl } from '../../../src/lib/supabase';
import { colors, radius, spacing } from '../../../src/theme';

type PendingAction =
  | { kind: 'remove_listing' }
  | { kind: 'hide_review'; hidden: boolean }
  | { kind: 'account'; state: AccountState }
  | { kind: 'report'; status: ReportStatus };

function describe(action: PendingAction): { title: string; confirm: string; needsReason: boolean } {
  if (action.kind === 'remove_listing') return { title: 'Remove this listing', confirm: 'Remove listing', needsReason: true };
  if (action.kind === 'hide_review') {
    const label = action.hidden ? 'Hide this review' : 'Show this review again';
    return { title: label, confirm: label, needsReason: true };
  }
  if (action.kind === 'account') {
    const label = { active: 'Restore account', restricted: 'Restrict account', suspended: 'Suspend account' }[action.state];
    return { title: label, confirm: label, needsReason: true };
  }
  const label = { open: 'Reopen', in_review: 'Keep in review', actioned: 'Close as actioned', dismissed: 'Dismiss report' }[action.status];
  return { title: label, confirm: label, needsReason: false };
}

export default function ReportDetail() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { userId } = useAuth();

  const [roles, setRoles] = useState<AdminRole[]>([]);
  const [report, setReport] = useState<ReportRow | null>(null);
  const [listing, setListing] = useState<ListingDetail | null>(null);
  const [subjectId, setSubjectId] = useState<string | null>(null);
  const [review, setReview] = useState<ReportedReview | null>(null);
  const [account, setAccount] = useState<AccountSummary | null>(null);
  const [conversation, setConversation] = useState<Message[] | null>(null);

  const [pending, setPending] = useState<PendingAction | null>(null);
  const [reason, setReason] = useState('');
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!id || !userId) return;
    try {
      const [myRoles, r] = await Promise.all([fetchMyRoles(userId), fetchReport(id)]);
      setRoles(myRoles);
      setReport(r);

      let subject: string | null = null;
      if (r.targetType === 'listing') {
        const l = await fetchListing(r.targetId);
        setListing(l);
        subject = l.sellerId;
      } else if (r.targetType === 'review') {
        setReview(await fetchReviewForStaff(r.targetId));
      } else if (r.targetType === 'user') {
        subject = r.targetId;
      } else if (r.targetType === 'message') {
        subject = await fetchMessageSender(r.targetId);
      }
      setSubjectId(subject);
      setAccount(subject ? await fetchAccount(subject) : null);
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, [id, userId]);

  useEffect(() => {
    load();
  }, [load]);

  async function openConversation() {
    if (!id) return;
    setBusy(true);
    setError('');
    try {
      setConversation(await readReportedConversation(id));
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  function start(action: PendingAction) {
    setPending(action);
    setReason('');
    setError('');
    setMessage('');
  }

  async function confirm() {
    if (!pending || !report) return;
    const meta = describe(pending);
    if (meta.needsReason) {
      const problem = reasonProblem(reason);
      if (problem) {
        setError(problem);
        return;
      }
    }

    setBusy(true);
    setError('');
    try {
      if (pending.kind === 'remove_listing') {
        await removeListing(report.targetId, reason);
        setMessage('Listing removed. Close the report when you are finished.');
      } else if (pending.kind === 'hide_review') {
        await setReviewHidden(report.targetId, pending.hidden, reason);
        setMessage('Review updated. Close the report when you are finished.');
      } else if (pending.kind === 'account' && subjectId) {
        await changeAccountState(subjectId, pending.state, reason);
        setMessage('Account updated. Close the report when you are finished.');
      } else if (pending.kind === 'report') {
        await resolveReport(report.id, pending.status, reason);
        setMessage('Report updated.');
      }
      setPending(null);
      setReason('');
      await load();
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!report) {
    return <View style={styles.center}>{error ? <Notice tone="error">{error}</Notice> : <Text style={styles.text}>Loading</Text>}</View>;
  }

  const reasonText = REPORT_REASONS.find((r) => r.value === report.reason)?.label ?? report.reason;
  const closed = report.status === 'actioned' || report.status === 'dismissed';
  const mayModerate = canModerate(roles);
  const mayClose = canHandleReports(roles);
  const sameAsMe = subjectId !== null && subjectId === userId;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {message ? <Notice>{message}</Notice> : null}

      <View style={styles.card}>
        <Text style={styles.kind}>
          {report.targetType} report · {report.status.replace('_', ' ')}
        </Text>
        <Text style={styles.title}>{reasonText}</Text>
        {report.details ? <Text style={styles.text}>{report.details}</Text> : null}
        <Text style={styles.meta}>{new Date(report.createdAt).toLocaleString()}</Text>
        {report.decisionNote ? <Text style={styles.meta}>Note: {report.decisionNote}</Text> : null}
      </View>

      {listing ? (
        <View style={styles.card}>
          <SectionTitle>Reported listing</SectionTitle>
          {listing.imagePaths.length > 0 ? (
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: spacing.sm }}>
              {listing.imagePaths.map((p) => (
                <Image key={p} source={{ uri: listingImageUrl(p) }} style={styles.photo} />
              ))}
            </ScrollView>
          ) : null}
          <Text style={styles.title}>{listing.title}</Text>
          <Text style={styles.text}>{formatKwacha(listing.price)}</Text>
          <Text style={styles.text}>{listing.description}</Text>
          <Text style={styles.meta}>Status: {listing.status}</Text>
        </View>
      ) : null}

      {review ? (
        <View style={styles.card}>
          <SectionTitle>Reported review</SectionTitle>
          <Text style={styles.title}>{review.rating} out of 5{review.hidden ? ' (hidden)' : ''}</Text>
          {review.comment ? <Text style={styles.text}>{review.comment}</Text> : <Text style={styles.meta}>No comment.</Text>}
        </View>
      ) : null}

      {report.targetType === 'message' ? (
        <View style={styles.card}>
          <SectionTitle>Reported message</SectionTitle>
          {conversation === null ? (
            <>
              <Text style={styles.text}>
                Private messages are closed to staff by default. Opening this conversation is written to the audit log with your name.
              </Text>
              {mayModerate ? (
                <Button title="Open the conversation" variant="secondary" onPress={openConversation} loading={busy} />
              ) : (
                <Text style={styles.meta}>Only moderators can open conversations.</Text>
              )}
            </>
          ) : (
            conversation.map((m) => (
              <View key={m.id} style={[styles.bubble, m.id === report.targetId && styles.flagged]}>
                <Text style={styles.meta}>
                  {m.senderId === subjectId ? 'Sender of reported message' : 'Other person'} · {new Date(m.createdAt).toLocaleString()}
                </Text>
                <Text style={styles.text}>{m.body}</Text>
              </View>
            ))
          )}
        </View>
      ) : null}

      {account ? (
        <View style={styles.card}>
          <SectionTitle>Account involved</SectionTitle>
          <Text style={styles.title}>{account.name}</Text>
          <Text style={styles.text}>State: {account.state}</Text>
        </View>
      ) : null}

      {pending ? (
        <View style={styles.card}>
          <SectionTitle>{describe(pending).title}</SectionTitle>
          <Field
            label={describe(pending).needsReason ? 'Reason (saved in the audit log)' : 'Note (optional)'}
            value={reason}
            onChangeText={setReason}
            multiline
            maxLength={500}
            style={{ minHeight: 80, textAlignVertical: 'top' }}
          />
          <Button title={describe(pending).confirm} onPress={confirm} loading={busy} variant={pending.kind === 'report' ? 'primary' : 'danger'} />
          <Button title="Back" variant="secondary" onPress={() => setPending(null)} disabled={busy} />
        </View>
      ) : (
        <View style={{ gap: spacing.sm }}>
          {mayModerate && listing && listing.status !== 'removed' ? (
            <Button title="Remove listing" variant="danger" onPress={() => start({ kind: 'remove_listing' })} />
          ) : null}

          {mayModerate && review ? (
            <Button
              title={review.hidden ? 'Show review again' : 'Hide review'}
              variant={review.hidden ? 'secondary' : 'danger'}
              onPress={() => start({ kind: 'hide_review', hidden: !review.hidden })}
            />
          ) : null}

          {mayModerate && account && !sameAsMe ? (
            <>
              {account.state === 'active' ? (
                <Button title="Restrict account" variant="danger" onPress={() => start({ kind: 'account', state: 'restricted' })} />
              ) : (
                <Button title="Restore account" variant="secondary" onPress={() => start({ kind: 'account', state: 'active' })} />
              )}
              {account.state !== 'suspended' ? (
                <Button title="Suspend account" variant="danger" onPress={() => start({ kind: 'account', state: 'suspended' })} />
              ) : null}
            </>
          ) : null}

          {mayClose && !closed ? (
            <>
              {report.status === 'open' ? (
                <Button title="Mark as in review" variant="secondary" onPress={() => start({ kind: 'report', status: 'in_review' })} />
              ) : null}
              <Button title="Close as actioned" onPress={() => start({ kind: 'report', status: 'actioned' })} />
              <Button title="Dismiss report" variant="secondary" onPress={() => start({ kind: 'report', status: 'dismissed' })} />
            </>
          ) : null}
        </View>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  center: { flex: 1, padding: spacing.xl, justifyContent: 'center', backgroundColor: colors.background },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  kind: { fontSize: 13, color: colors.muted, textTransform: 'capitalize' },
  title: { fontSize: 17, fontWeight: '600', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.text },
  meta: { fontSize: 12, color: colors.muted },
  photo: { width: 140, height: 140, borderRadius: radius.sm, backgroundColor: colors.primarySoft },
  bubble: { padding: spacing.sm, borderRadius: radius.sm, borderWidth: 1, borderColor: colors.border, gap: 2 },
  flagged: { borderColor: colors.danger, backgroundColor: '#FBE9E7' },
});
