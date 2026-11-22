import type { ApplicationKind, ApplicationStatus, UserFilter } from '../../domain/trustAdmin';
import { supabase } from '../../lib/supabase';
import { signedUrl } from '../trust/api';
import type { AccountState } from '../admin/api';

export const PAGE_SIZE = 30;

export type Application = {
  kind: ApplicationKind;
  id: string;
  subjectId: string;
  subjectUserId: string;
  subjectName: string;
  detail: string;
  status: ApplicationStatus;
  submittedAt: string;
  reviewedAt: string | null;
  reviewerName: string | null;
  reviewerNote: string | null;
  hasDocument: boolean;
};

type ApplicationRow = {
  kind: string;
  id: string;
  subject_id: string;
  subject_user_id?: string;
  subject_name: string;
  detail: string;
  status: string;
  submitted_at: string;
  reviewed_at: string | null;
  reviewer_name: string | null;
  reviewer_note: string | null;
  has_document?: boolean;
};

function toApplication(r: ApplicationRow): Application {
  return {
    kind: r.kind as ApplicationKind,
    id: r.id,
    subjectId: r.subject_id,
    subjectUserId: r.subject_user_id ?? r.subject_id,
    subjectName: r.subject_name,
    detail: r.detail,
    status: r.status as ApplicationStatus,
    submittedAt: r.submitted_at,
    reviewedAt: r.reviewed_at,
    reviewerName: r.reviewer_name,
    reviewerNote: r.reviewer_note,
    hasDocument: r.has_document ?? false,
  };
}

export async function fetchApplications(
  kind: ApplicationKind,
  status: ApplicationStatus,
  search: string,
  offset = 0,
): Promise<Application[]> {
  const { data, error } = await supabase.rpc('trust_applications', {
    p_kind: kind,
    p_status: status,
    p_search: search.trim() || null,
    p_limit: PAGE_SIZE,
    p_offset: offset,
  });
  if (error) throw error;
  return ((data ?? []) as ApplicationRow[]).map(toApplication);
}

export async function decideApplication(app: Application, approve: boolean, note: string): Promise<void> {
  const fn = app.kind === 'identity' ? 'review_identity_verification' : 'review_business_verification';
  const { error } = await supabase.rpc(fn, { p_id: app.id, p_approve: approve, p_note: note.trim() || null });
  if (error) throw error;
}

// The database writes the "document opened" audit entry first and hands back the path.
// Only then do we ask storage for a link that expires after five minutes.
export async function openDocument(app: Application): Promise<string> {
  const { data, error } = await supabase.rpc('trust_open_document', { p_kind: app.kind, p_id: app.id });
  if (error) throw error;
  const bucket = app.kind === 'identity' ? 'identity-documents' : 'business-documents';
  return signedUrl(bucket, data as string);
}

export type TrustUser = {
  id: string;
  displayName: string;
  verificationLevel: 'unverified' | 'contact_verified' | 'identity_verified';
  accountState: AccountState;
  joinedAt: string;
  stateReason: string | null;
  stateChangedAt: string | null;
};

export async function fetchTrustUsers(filter: UserFilter, search: string, offset = 0): Promise<TrustUser[]> {
  const { data, error } = await supabase.rpc('trust_users', {
    p_filter: filter,
    p_search: search.trim() || null,
    p_limit: PAGE_SIZE,
    p_offset: offset,
  });
  if (error) throw error;
  return (
    (data ?? []) as Array<{
      id: string;
      display_name: string;
      verification_level: TrustUser['verificationLevel'];
      account_state: AccountState;
      joined_at: string;
      state_reason: string | null;
      state_changed_at: string | null;
    }>
  ).map((u) => ({
    id: u.id,
    displayName: u.display_name,
    verificationLevel: u.verification_level,
    accountState: u.account_state,
    joinedAt: u.joined_at,
    stateReason: u.state_reason,
    stateChangedAt: u.state_changed_at,
  }));
}

export type TrustProfile = {
  id: string;
  displayName: string;
  bio: string | null;
  verificationLevel: TrustUser['verificationLevel'];
  accountState: AccountState;
  joinedAt: string;
  stateReason: string | null;
  stateChangedAt: string | null;
  staffRoles: string[];
  listingsTotal: number;
  listingsActive: number;
  ordersAsBuyer: number;
  ordersAsSeller: number;
  ordersCompleted: number;
  disputesOpened: number;
  reportsAgainst: number;
  reportsOpenAgainst: number;
  businesses: Array<{ id: string; name: string; verificationStatus: string }>;
};

export async function fetchTrustProfile(userId: string): Promise<TrustProfile> {
  const { data, error } = await supabase.rpc('trust_user_profile', { p_user: userId });
  if (error) throw error;
  const p = data as Record<string, any>;
  return {
    id: p.id,
    displayName: p.display_name,
    bio: p.bio,
    verificationLevel: p.verification_level,
    accountState: p.account_state,
    joinedAt: p.joined_at,
    stateReason: p.state_reason,
    stateChangedAt: p.state_changed_at,
    staffRoles: p.staff_roles ?? [],
    listingsTotal: Number(p.listings_total),
    listingsActive: Number(p.listings_active),
    ordersAsBuyer: Number(p.orders_as_buyer),
    ordersAsSeller: Number(p.orders_as_seller),
    ordersCompleted: Number(p.orders_completed),
    disputesOpened: Number(p.disputes_opened),
    reportsAgainst: Number(p.reports_against),
    reportsOpenAgainst: Number(p.reports_open_against),
    businesses: (p.businesses ?? []).map((b: any) => ({ id: b.id, name: b.name, verificationStatus: b.verification_status })),
  };
}

export async function fetchVerificationHistory(userId: string): Promise<Application[]> {
  const { data, error } = await supabase.rpc('trust_verification_history', { p_user: userId });
  if (error) throw error;
  return ((data ?? []) as ApplicationRow[]).map((r) => toApplication({ ...r, subject_id: r.id }));
}

export type TrustAuditEntry = {
  id: number;
  createdAt: string;
  actorName: string | null;
  action: string;
  targetType: string | null;
  targetId: string | null;
  metadata: Record<string, unknown>;
};

export async function fetchTrustAudit(targetUserId: string | null, offset = 0): Promise<TrustAuditEntry[]> {
  const { data, error } = await supabase.rpc('trust_audit_trail', {
    p_target_type: targetUserId ? 'user' : null,
    p_target_id: targetUserId,
    p_actor: null,
    p_limit: 50,
    p_offset: offset,
  });
  if (error) throw error;
  return (
    (data ?? []) as Array<{
      id: number;
      created_at: string;
      actor_name: string | null;
      action: string;
      target_type: string | null;
      target_id: string | null;
      metadata: Record<string, unknown> | null;
    }>
  ).map((a) => ({
    id: a.id,
    createdAt: a.created_at,
    actorName: a.actor_name,
    action: a.action,
    targetType: a.target_type,
    targetId: a.target_id,
    metadata: a.metadata ?? {},
  }));
}

export async function changeAccountState(userId: string, state: AccountState, reason: string): Promise<void> {
  const { error } = await supabase.rpc('set_account_state', { p_user: userId, p_state: state, p_reason: reason.trim() });
  if (error) throw error;
}
