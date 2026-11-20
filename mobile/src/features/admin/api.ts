import type { AdminRole } from '../../domain/admin';
import type { ItemCondition } from '../../domain/listing';
import { supabase } from '../../lib/supabase';
import { toMessage, type Message } from '../chat/api';

export type ReportTarget = 'listing' | 'user' | 'message' | 'business' | 'review';
export type ReportStatus = 'open' | 'in_review' | 'actioned' | 'dismissed';
export type AccountState = 'active' | 'restricted' | 'suspended';

// ---------------------------------------------------------------------------
// Staff access and two-factor
// ---------------------------------------------------------------------------

export async function fetchMyRoles(userId: string): Promise<AdminRole[]> {
  const { data, error } = await supabase.from('admin_roles').select('role').eq('user_id', userId);
  if (error) throw error;
  return (data ?? []).map((r) => r.role as AdminRole);
}

export async function fetchAssurance() {
  const { data, error } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (error) throw error;
  return { currentLevel: data.currentLevel, nextLevel: data.nextLevel };
}

export async function verifiedFactorId(): Promise<string | null> {
  const { data, error } = await supabase.auth.mfa.listFactors();
  if (error) throw error;
  return data.totp[0]?.id ?? null;
}

// Starts adding an authenticator app. Half-finished attempts are cleared first,
// otherwise the second try fails with a name clash.
export async function startEnrolment(): Promise<{ factorId: string; secret: string }> {
  const { data: existing, error: listError } = await supabase.auth.mfa.listFactors();
  if (listError) throw listError;
  for (const factor of existing.all) {
    if (factor.factor_type === 'totp' && factor.status === 'unverified') {
      await supabase.auth.mfa.unenroll({ factorId: factor.id });
    }
  }

  const { data, error } = await supabase.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'ZedMarket staff' });
  if (error) throw error;
  return { factorId: data.id, secret: data.totp.secret };
}

export async function confirmCode(factorId: string, code: string) {
  const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId, code });
  if (error) throw error;
  await supabase.auth.refreshSession();
}

// ---------------------------------------------------------------------------
// Listing review queue
// ---------------------------------------------------------------------------

export type QueuedListing = {
  id: string;
  title: string;
  price: number;
  condition: ItemCondition;
  sellerId: string;
  sellerName: string;
  sellerState: AccountState;
  note: string | null;
  postedAt: string;
  imagePaths: string[];
};

export async function fetchPendingListings(): Promise<QueuedListing[]> {
  const { data, error } = await supabase
    .from('listings')
    .select(
      `id, title, price_zmw, condition, moderation_note, created_at,
       seller:profiles!inner(id, display_name, account_state),
       images:listing_images(storage_path, position)`,
    )
    .eq('moderation_status', 'pending')
    .eq('status', 'active')
    .order('created_at', { ascending: true })
    .limit(50);
  if (error) throw error;

  const rows = data as unknown as {
    id: string;
    title: string;
    price_zmw: number;
    condition: ItemCondition;
    moderation_note: string | null;
    created_at: string;
    seller: { id: string; display_name: string; account_state: AccountState };
    images: { storage_path: string; position: number }[] | null;
  }[];

  return rows.map((r) => ({
    id: r.id,
    title: r.title,
    price: Number(r.price_zmw),
    condition: r.condition,
    sellerId: r.seller.id,
    sellerName: r.seller.display_name,
    sellerState: r.seller.account_state,
    note: r.moderation_note,
    postedAt: r.created_at,
    imagePaths: [...(r.images ?? [])].sort((a, b) => a.position - b.position).map((i) => i.storage_path),
  }));
}

export async function approveListing(listingId: string, note: string) {
  const { error } = await supabase.rpc('moderate_listing', {
    p_listing_id: listingId,
    p_decision: 'approved',
    p_note: note.trim() || null,
  });
  if (error) throw error;
}

export async function rejectListing(listingId: string, note: string) {
  const { error } = await supabase.rpc('moderate_listing', {
    p_listing_id: listingId,
    p_decision: 'rejected',
    p_note: note.trim(),
  });
  if (error) throw error;
}

export async function removeListing(listingId: string, reason: string) {
  const { error } = await supabase.rpc('remove_listing', { p_listing_id: listingId, p_reason: reason.trim() });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

export type ReportRow = {
  id: string;
  targetType: ReportTarget;
  targetId: string;
  reason: string;
  details: string | null;
  status: ReportStatus;
  decisionNote: string | null;
  createdAt: string;
};

type RawReport = {
  id: string;
  target_type: ReportTarget;
  target_id: string;
  reason: string;
  details: string | null;
  status: ReportStatus;
  decision_note: string | null;
  created_at: string;
};

const REPORT_COLUMNS = 'id, target_type, target_id, reason, details, status, decision_note, created_at';

function toReport(r: RawReport): ReportRow {
  return {
    id: r.id,
    targetType: r.target_type,
    targetId: r.target_id,
    reason: r.reason,
    details: r.details,
    status: r.status,
    decisionNote: r.decision_note,
    createdAt: r.created_at,
  };
}

export async function fetchOpenReports(): Promise<ReportRow[]> {
  const { data, error } = await supabase
    .from('reports')
    .select(REPORT_COLUMNS)
    .in('status', ['open', 'in_review'])
    .order('created_at', { ascending: true })
    .limit(50);
  if (error) throw error;
  return (data as RawReport[]).map(toReport);
}

export async function fetchReport(id: string): Promise<ReportRow> {
  const { data, error } = await supabase.from('reports').select(REPORT_COLUMNS).eq('id', id).single();
  if (error) throw error;
  return toReport(data as RawReport);
}

export async function resolveReport(reportId: string, status: ReportStatus, note: string) {
  const { error } = await supabase.rpc('resolve_report', {
    p_report_id: reportId,
    p_status: status,
    p_note: note.trim() || null,
  });
  if (error) throw error;
}

// Opens the conversation behind a reported message. The database records that
// this happened in the audit log every time.
export async function readReportedConversation(reportId: string): Promise<Message[]> {
  const { data, error } = await supabase.rpc('staff_read_reported_conversation', { p_report_id: reportId });
  if (error) throw error;
  return (data as Parameters<typeof toMessage>[0][]).map(toMessage);
}

export async function fetchMessageSender(messageId: string): Promise<string | null> {
  const { data, error } = await supabase.from('messages').select('sender_id').eq('id', messageId).maybeSingle();
  if (error) throw error;
  return data?.sender_id ?? null;
}

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

export type AccountSummary = { id: string; name: string; state: AccountState };

export async function fetchAccount(userId: string): Promise<AccountSummary | null> {
  const { data, error } = await supabase
    .from('profiles')
    .select('id, display_name, account_state')
    .eq('id', userId)
    .maybeSingle();
  if (error) throw error;
  return data ? { id: data.id, name: data.display_name, state: data.account_state as AccountState } : null;
}

export async function changeAccountState(userId: string, state: AccountState, reason: string) {
  const { error } = await supabase.rpc('set_account_state', {
    p_user: userId,
    p_state: state,
    p_reason: reason.trim(),
  });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Verification requests (identity and business)
// ---------------------------------------------------------------------------

export type VerificationItem = {
  id: string;
  kind: 'identity' | 'business';
  title: string;
  detail: string;
  documentPath: string | null;
  submittedAt: string;
};

export async function fetchPendingVerifications(): Promise<VerificationItem[]> {
  const [identity, business] = await Promise.all([
    supabase
      .from('identity_verifications')
      .select('id, document_type, document_path, created_at, person:profiles!identity_verifications_user_id_fkey(display_name)')
      .eq('status', 'pending')
      .order('created_at', { ascending: true })
      .limit(50),
    supabase
      .from('business_verifications')
      .select('id, registration_number, document_path, created_at, business:businesses(name)')
      .eq('status', 'pending')
      .order('created_at', { ascending: true })
      .limit(50),
  ]);
  if (identity.error) throw identity.error;
  if (business.error) throw business.error;

  const people = identity.data as unknown as {
    id: string;
    document_type: string;
    document_path: string;
    created_at: string;
    person: { display_name: string } | null;
  }[];
  const shops = business.data as unknown as {
    id: string;
    registration_number: string;
    document_path: string | null;
    created_at: string;
    business: { name: string } | null;
  }[];

  const items: VerificationItem[] = [
    ...people.map((r) => ({
      id: r.id,
      kind: 'identity' as const,
      title: r.person?.display_name ?? 'Unknown person',
      detail: r.document_type.replace('_', ' '),
      documentPath: r.document_path,
      submittedAt: r.created_at,
    })),
    ...shops.map((r) => ({
      id: r.id,
      kind: 'business' as const,
      title: r.business?.name ?? 'Unknown business',
      detail: `Registration number ${r.registration_number}`,
      documentPath: r.document_path,
      submittedAt: r.created_at,
    })),
  ];
  return items.sort((a, b) => a.submittedAt.localeCompare(b.submittedAt));
}

export async function decideVerification(item: VerificationItem, approve: boolean, note: string) {
  const fn = item.kind === 'identity' ? 'review_identity_verification' : 'review_business_verification';
  const { error } = await supabase.rpc(fn, { p_id: item.id, p_approve: approve, p_note: note.trim() || null });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Disputes
// ---------------------------------------------------------------------------

export type StaffDispute = {
  id: string;
  orderRef: string;
  reason: string;
  status: 'open' | 'awaiting_info' | 'resolved' | 'rejected';
  createdAt: string;
};

export async function fetchOpenDisputes(): Promise<StaffDispute[]> {
  const { data, error } = await supabase
    .from('disputes')
    .select('id, reason, status, created_at, order:orders(ref)')
    .in('status', ['open', 'awaiting_info'])
    .order('created_at', { ascending: true })
    .limit(50);
  if (error) throw error;
  const rows = data as unknown as {
    id: string;
    reason: string;
    status: StaffDispute['status'];
    created_at: string;
    order: { ref: string } | null;
  }[];
  return rows.map((r) => ({ id: r.id, orderRef: r.order?.ref ?? '', reason: r.reason, status: r.status, createdAt: r.created_at }));
}

export async function decideDispute(disputeId: string, status: 'awaiting_info' | 'resolved' | 'rejected', outcome: string) {
  const { error } = await supabase.rpc('resolve_dispute', { p_dispute_id: disputeId, p_status: status, p_outcome: outcome.trim() });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Appeals
// ---------------------------------------------------------------------------

export type StaffAppeal = {
  id: string;
  userId: string;
  userName: string;
  targetType: ReportTarget;
  targetId: string;
  message: string;
  createdAt: string;
};

export async function fetchOpenAppeals(): Promise<StaffAppeal[]> {
  const { data, error } = await supabase
    .from('appeals')
    .select('id, user_id, target_type, target_id, message, created_at, person:profiles!appeals_user_id_fkey(display_name)')
    .eq('status', 'open')
    .order('created_at', { ascending: true })
    .limit(50);
  if (error) throw error;
  const rows = data as unknown as {
    id: string;
    user_id: string;
    target_type: ReportTarget;
    target_id: string;
    message: string;
    created_at: string;
    person: { display_name: string } | null;
  }[];
  return rows.map((r) => ({
    id: r.id,
    userId: r.user_id,
    userName: r.person?.display_name ?? 'Unknown person',
    targetType: r.target_type,
    targetId: r.target_id,
    message: r.message,
    createdAt: r.created_at,
  }));
}

export async function decideAppeal(appealId: string, status: 'upheld' | 'overturned', note: string) {
  const { error } = await supabase.rpc('review_appeal', { p_appeal_id: appealId, p_status: status, p_note: note.trim() });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Risk flags
// ---------------------------------------------------------------------------

export type RiskFlag = { id: string; subjectType: string; subjectId: string; signal: string; detail: Record<string, unknown>; createdAt: string };

export async function fetchOpenFlags(): Promise<RiskFlag[]> {
  const { data, error } = await supabase
    .from('risk_flags')
    .select('id, subject_type, subject_id, signal, detail, created_at')
    .eq('status', 'open')
    .order('created_at', { ascending: true })
    .limit(50);
  if (error) throw error;
  return (data ?? []).map((f) => ({
    id: f.id as string,
    subjectType: f.subject_type as string,
    subjectId: f.subject_id as string,
    signal: f.signal as string,
    detail: (f.detail ?? {}) as Record<string, unknown>,
    createdAt: f.created_at as string,
  }));
}

export async function markFlagReviewed(flagId: string) {
  const { error } = await supabase.rpc('mark_risk_flag_reviewed', { p_flag_id: flagId });
  if (error) throw error;
}

export async function setReviewHidden(reviewId: string, hidden: boolean, reason: string) {
  const { error } = await supabase.rpc('set_review_hidden', { p_review_id: reviewId, p_hidden: hidden, p_reason: reason.trim() });
  if (error) throw error;
}

export type ReportedReview = { id: string; rating: number; comment: string | null; hidden: boolean };

export async function fetchReviewForStaff(reviewId: string): Promise<ReportedReview | null> {
  const { data, error } = await supabase.from('reviews').select('id, rating, comment, is_hidden').eq('id', reviewId).maybeSingle();
  if (error) throw error;
  return data ? { id: data.id, rating: data.rating, comment: data.comment, hidden: data.is_hidden } : null;
}

// ---------------------------------------------------------------------------
// Team and audit log (technical admins)
// ---------------------------------------------------------------------------

export type StaffMember = { userId: string; name: string; role: AdminRole; grantedAt: string };

export async function fetchTeam(): Promise<StaffMember[]> {
  const { data, error } = await supabase
    .from('admin_roles')
    .select('user_id, role, granted_at, person:profiles!admin_roles_user_id_fkey(display_name)')
    .order('granted_at', { ascending: true });
  if (error) throw error;
  const rows = data as unknown as { user_id: string; role: AdminRole; granted_at: string; person: { display_name: string } | null }[];
  return rows.map((r) => ({ userId: r.user_id, name: r.person?.display_name ?? 'Unknown', role: r.role, grantedAt: r.granted_at }));
}

export async function findPeople(term: string): Promise<{ id: string; name: string }[]> {
  const clean = term.replace(/[%_,()\\]/g, ' ').trim();
  if (clean.length < 2) return [];
  const { data, error } = await supabase.from('profiles').select('id, display_name').ilike('display_name', `%${clean}%`).limit(10);
  if (error) throw error;
  return (data ?? []).map((p) => ({ id: p.id as string, name: p.display_name as string }));
}

export async function grantRole(userId: string, role: AdminRole) {
  const { error } = await supabase.rpc('grant_admin_role', { p_user: userId, p_role: role });
  if (error) throw error;
}

export async function revokeRole(userId: string, role: AdminRole) {
  const { error } = await supabase.rpc('revoke_admin_role', { p_user: userId, p_role: role });
  if (error) throw error;
}

export type Approval = { id: string; action: string; targetType: string | null; targetId: string | null; requestedBy: string; createdAt: string };

export async function fetchPendingApprovals(): Promise<Approval[]> {
  const { data, error } = await supabase
    .from('admin_approvals')
    .select('id, action, target_type, target_id, requested_by, created_at')
    .eq('status', 'pending')
    .order('created_at', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((a) => ({
    id: a.id as string,
    action: a.action as string,
    targetType: a.target_type as string | null,
    targetId: a.target_id as string | null,
    requestedBy: a.requested_by as string,
    createdAt: a.created_at as string,
  }));
}

export async function decideApproval(id: string, approve: boolean) {
  const { error } = await supabase.rpc('decide_admin_approval', { p_id: id, p_approve: approve });
  if (error) throw error;
}

export type AuditEntry = { id: number; actorId: string | null; action: string; targetType: string | null; targetId: string | null; createdAt: string };

export async function fetchAudit(): Promise<AuditEntry[]> {
  const { data, error } = await supabase
    .from('audit_logs')
    .select('id, actor_id, action, target_type, target_id, created_at')
    .order('id', { ascending: false })
    .limit(100);
  if (error) throw error;
  return (data ?? []).map((a) => ({
    id: a.id as number,
    actorId: a.actor_id as string | null,
    action: a.action as string,
    targetType: a.target_type as string | null,
    targetId: a.target_id as string | null,
    createdAt: a.created_at as string,
  }));
}
