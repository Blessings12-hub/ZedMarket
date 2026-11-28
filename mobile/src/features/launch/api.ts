import { toReplySpeed, type ReplySpeed } from '../../domain/replySpeed';
import { supabase } from '../../lib/supabase';

export type HealthSummary = {
  errors24h: number;
  errorKinds24h: number;
  topErrors: { message: string; route: string | null; platform: string; total: number; lastSeen: string }[];
  ticketsLate: number;
  ticketsUnassigned: number;
  sellerApplicationsWaiting: number;
  listingsWaiting: number;
  reportsOpen: number;
  disputesOpen: number;
  notificationsFailed24h: number;
  checkedAt: string;
};

type RawHealth = {
  errors_24h: number; error_kinds_24h: number; top_errors: { message: string; route: string | null; platform: string; total: number; last_seen: string }[];
  tickets_late: number; tickets_unassigned: number; seller_applications_waiting: number; listings_waiting: number; reports_open: number;
  disputes_open: number; notifications_failed_24h: number; checked_at: string;
};

export async function fetchHealthSummary(): Promise<HealthSummary> {
  const { data, error } = await supabase.rpc('staff_health_summary');
  if (error) throw error;
  const r = data as RawHealth;
  return {
    errors24h: r.errors_24h, errorKinds24h: r.error_kinds_24h,
    topErrors: (r.top_errors ?? []).map((e) => ({ message: e.message, route: e.route, platform: e.platform, total: e.total, lastSeen: e.last_seen })),
    ticketsLate: r.tickets_late, ticketsUnassigned: r.tickets_unassigned, sellerApplicationsWaiting: r.seller_applications_waiting,
    listingsWaiting: r.listings_waiting, reportsOpen: r.reports_open, disputesOpen: r.disputes_open,
    notificationsFailed24h: r.notifications_failed_24h, checkedAt: r.checked_at,
  };
}

// A missing answer is "no badge": the page must work even if this call fails.
export async function fetchReplySpeed(sellerId: string): Promise<ReplySpeed | null> {
  const { data, error } = await supabase.rpc('seller_reply_speed', { p_seller: sellerId });
  return error ? null : toReplySpeed(data);
}

export async function deleteMyAccount(reason?: string): Promise<void> {
  const { error } = await supabase.rpc('account_delete', { p_reason: reason ?? null });
  if (error) throw error;
}

export async function fetchMyInviteCode(): Promise<string> {
  const { data, error } = await supabase.rpc('referral_code_mine');
  if (error) throw error;
  return String(data);
}

export async function fetchInviteCount(): Promise<number> {
  const { data, error } = await supabase.rpc('referral_count');
  if (error) throw error;
  return Number(data ?? 0);
}

export async function redeemInviteCode(code: string): Promise<void> {
  const { error } = await supabase.rpc('referral_redeem', { p_code: code });
  if (error) throw error;
}
