import { supabase } from '../../lib/supabase';
import { fetchMyRoles } from '../admin/api';
import { fetchMyListings } from '../listings/api';
import { countUnreadAlerts } from '../listings/api';
import { countUnreadNotifications } from '../notifications/api';
import { paymentsEnabled } from '../payments/api';
import { pickOnePhoto, toAppeal, toDispute, type Appeal, type Dispute } from '../trust/api';
import type { HubBusiness, HubFacts } from './hub';

export type HubProfile = {
  displayName: string;
  bio: string;
  avatarPath: string | null;
  level: 'unverified' | 'contact_verified' | 'identity_verified';
  state: 'active' | 'restricted' | 'suspended';
  createdAt: string;
};

// Every number the hub shows is counted from real rows. A failed piece of data becomes zero or "off" rather than
// blocking the whole page.
export async function fetchHub(userId: string): Promise<{ profile: HubProfile; facts: Omit<HubFacts, 'context'> }> {
  const [p, app, listings, roles, memberships, unreadN, unreadA, payOn, mine, requests] = await Promise.all([
    supabase.from('profiles').select('display_name, bio, avatar_path, verification_level, account_state, created_at, seller_status').eq('id', userId).single(),
    supabase.rpc('seller_application_mine'),
    fetchMyListings(userId).catch(() => []),
    fetchMyRoles(userId).catch(() => []),
    supabase.from('business_members').select('role, business:businesses(id, name, slug, verification_status)').eq('user_id', userId),
    countUnreadNotifications().catch(() => 0),
    countUnreadAlerts().catch(() => 0),
    paymentsEnabled().catch(() => false),
    supabase.from('orders').select('id', { count: 'exact', head: true }).eq('buyer_id', userId).in('status', ['requested', 'confirmed']),
    supabase.from('orders').select('id', { count: 'exact', head: true }).eq('seller_id', userId).is('business_id', null).eq('status', 'requested'),
  ]);
  if (p.error) throw p.error;
  const r = p.data as { display_name: string; bio: string | null; avatar_path: string | null; verification_level: HubProfile['level']; account_state: HubProfile['state']; created_at: string; seller_status: HubFacts['sellerStatus'] };

  const rows = (memberships.data ?? []) as unknown as { role: HubBusiness['role']; business: { id: string; name: string; slug: string; verification_status: string } | null }[];
  const businesses: HubBusiness[] = rows.flatMap((m) =>
    m.business ? [{ id: m.business.id, name: m.business.name, slug: m.business.slug, role: m.role, verified: m.business.verification_status === 'verified' }] : [],
  );

  return {
    profile: { displayName: r.display_name, bio: r.bio ?? '', avatarPath: r.avatar_path, level: r.verification_level, state: r.account_state, createdAt: r.created_at },
    facts: {
      isStaff: roles.length > 0,
      isSeller: r.seller_status === 'active',
      sellerStatus: r.seller_status ?? 'none',
      sellerApplication: ((app.data as { application: { status: HubFacts['sellerApplication'] } | null } | null)?.application?.status) ?? null,
      paymentsOn: payOn,
      unreadNotifications: unreadN,
      unreadAlerts: unreadA,
      openRequestsToMe: requests.count ?? 0,
      activeBuying: mine.count ?? 0,
      listings: {
        total: listings.length,
        live: listings.filter((l) => l.status === 'active' && l.moderationStatus === 'approved').length,
        waiting: listings.filter((l) => l.moderationStatus === 'pending').length,
      },
      businesses,
    },
  };
}

export function avatarUrl(path: string | null): string | null {
  return path ? supabase.storage.from('avatars').getPublicUrl(path).data.publicUrl : null;
}

export async function saveProfile(userId: string, displayName: string, bio: string) {
  const { error } = await supabase.from('profiles').update({ display_name: displayName.trim(), bio: bio.trim() || null }).eq('id', userId);
  if (error) throw error;
}

// Pick a photo, upload it into the person's own folder in the public avatars bucket, and point the profile at it.
export async function changeAvatar(userId: string): Promise<string | null> {
  const uri = await pickOnePhoto();
  if (!uri) return null;
  const body = await (await fetch(uri)).arrayBuffer();
  const path = `${userId}/avatar-${Date.now()}.jpg`;
  const up = await supabase.storage.from('avatars').upload(path, body, { contentType: 'image/jpeg', upsert: false });
  if (up.error) throw up.error;
  const { error } = await supabase.from('profiles').update({ avatar_path: path }).eq('id', userId);
  if (error) throw error;
  return path;
}

// ----- security (uses Supabase sign-in as it is; no new rules) -----
export async function changePassword(newPassword: string) {
  const { error } = await supabase.auth.updateUser({ password: newPassword });
  if (error) throw error;
}
export async function resendConfirmation(email: string) {
  const { error } = await supabase.auth.resend({ type: 'signup', email });
  if (error) throw error;
}
export async function sendResetEmail(email: string) {
  const { error } = await supabase.auth.resetPasswordForEmail(email);
  if (error) throw error;
}
export async function signOutOtherDevices() {
  const { error } = await supabase.auth.signOut({ scope: 'others' });
  if (error) throw error;
}

// ----- reviews -----
export type WrittenReview = { id: string; rating: number; comment: string | null; createdAt: string; item: string; about: string };
export async function fetchReviewsIWrote(userId: string): Promise<WrittenReview[]> {
  const { data, error } = await supabase
    .from('reviews')
    .select('id, rating, comment, created_at, order:orders(item_title), about:profiles!reviews_reviewee_id_fkey(display_name)')
    .eq('reviewer_id', userId)
    .order('created_at', { ascending: false })
    .limit(50);
  if (error) throw error;
  const rows = data as unknown as { id: string; rating: number; comment: string | null; created_at: string; order: { item_title: string } | null; about: { display_name: string } | null }[];
  return rows.map((r) => ({ id: r.id, rating: r.rating, comment: r.comment, createdAt: r.created_at, item: r.order?.item_title ?? 'An order', about: r.about?.display_name ?? 'A seller' }));
}

// ----- cases -----
export type MyReport = { id: string; targetType: string; reason: string; status: string; createdAt: string };
export async function fetchMyCases(userId: string): Promise<{ disputes: Dispute[]; appeals: Appeal[]; reports: MyReport[] }> {
  const [d, a, r] = await Promise.all([
    // Staff can read every dispute, so the filter on the order's two people keeps this list to my own cases.
    supabase
      .from('disputes')
      .select('id, order_id, reason, details, status, outcome, opened_by, created_at, order:orders!inner(buyer_id, seller_id)')
      .or(`buyer_id.eq.${userId},seller_id.eq.${userId}`, { referencedTable: 'orders' })
      .order('created_at', { ascending: false })
      .limit(50),
    supabase.from('appeals').select('id, target_type, target_id, message, status, reviewer_note, created_at').eq('user_id', userId).order('created_at', { ascending: false }).limit(50),
    supabase.from('reports').select('id, target_type, reason, status, created_at').eq('reporter_id', userId).order('created_at', { ascending: false }).limit(50),
  ]);
  if (d.error) throw d.error;
  if (a.error) throw a.error;
  if (r.error) throw r.error;
  return {
    disputes: (d.data as Parameters<typeof toDispute>[0][]).map(toDispute),
    appeals: (a.data as Parameters<typeof toAppeal>[0][]).map(toAppeal),
    reports: (r.data as { id: string; target_type: string; reason: string; status: string; created_at: string }[]).map((x) => ({ id: x.id, targetType: x.target_type, reason: x.reason, status: x.status, createdAt: x.created_at })),
  };
}
