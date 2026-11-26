import * as ImageManipulator from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';

import type { DocumentType, ReviewState } from '../../domain/trust';
import { supabase } from '../../lib/supabase';
import { readPhoto, uploadObject } from '../../lib/storage';

// ---------------------------------------------------------------------------
// Photos for private files (ID, registration papers, dispute evidence)
// ---------------------------------------------------------------------------

const DOCUMENT_WIDTH = 1600;

export async function pickOnePhoto(): Promise<string | null> {
  const result = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], allowsMultipleSelection: false, quality: 1 });
  if (result.canceled || !result.assets[0]) return null;

  const asset = result.assets[0];
  const actions = asset.width > DOCUMENT_WIDTH ? [{ resize: { width: DOCUMENT_WIDTH } }] : [];
  // Re-encoding also removes location data stored inside the photo.
  const out = await ImageManipulator.manipulateAsync(asset.uri, actions, {
    compress: 0.8,
    format: ImageManipulator.SaveFormat.JPEG,
  });
  return out.uri;
}

export type PrivateBucket = 'identity-documents' | 'business-documents' | 'dispute-evidence' | 'support-evidence';

export async function uploadPrivate(bucket: PrivateBucket, userId: string, folder: string, uri: string): Promise<string> {
  const body = await readPhoto(uri);
  const path = `${userId}/${folder}/${Date.now()}.jpg`;
  await uploadObject(bucket, path, body);
  return path;
}

// Private files are only ever shown through a link that stops working after a few minutes.
export async function signedUrl(bucket: PrivateBucket, path: string): Promise<string> {
  const { data, error } = await supabase.storage.from(bucket).createSignedUrl(path, 300);
  if (error) throw error;
  return data.signedUrl;
}

// ---------------------------------------------------------------------------
// Identity verification
// ---------------------------------------------------------------------------

export type VerificationRequest = { id: string; state: ReviewState; note: string | null; submittedAt: string };

export async function fetchMyIdentityRequest(userId: string): Promise<VerificationRequest | null> {
  const { data, error } = await supabase
    .from('identity_verifications')
    .select('id, status, reviewer_note, created_at')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data ? { id: data.id, state: data.status as ReviewState, note: data.reviewer_note, submittedAt: data.created_at } : null;
}

export async function submitIdentity(userId: string, type: DocumentType, photoUri: string) {
  const path = await uploadPrivate('identity-documents', userId, 'id', photoUri);
  const { error } = await supabase.from('identity_verifications').insert({ document_type: type, document_path: path });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Businesses
// ---------------------------------------------------------------------------

export type MyBusiness = { id: string; name: string; slug: string; status: 'unverified' | 'pending' | 'verified' | 'rejected' };

export async function fetchMyBusinesses(userId: string): Promise<MyBusiness[]> {
  const { data, error } = await supabase
    .from('business_members')
    .select('role, business:businesses(id, name, slug, verification_status)')
    .eq('user_id', userId)
    .eq('role', 'owner');
  if (error) throw error;

  const rows = data as unknown as {
    business: { id: string; name: string; slug: string; verification_status: MyBusiness['status'] } | null;
  }[];
  return rows.flatMap((r) =>
    r.business ? [{ id: r.business.id, name: r.business.name, slug: r.business.slug, status: r.business.verification_status }] : [],
  );
}

export async function createBusiness(name: string, slug: string, description: string): Promise<string> {
  const { data, error } = await supabase
    .from('businesses')
    .insert({ name: name.trim(), slug, description: description.trim() || null })
    .select('id')
    .single();
  if (error) {
    if (error.code === '23505') throw new Error('That shop name is already taken. Try adding your area, for example "Kabulonga Electronics".');
    throw error;
  }
  return data.id as string;
}

export async function fetchBusinessRequest(businessId: string): Promise<VerificationRequest | null> {
  const { data, error } = await supabase
    .from('business_verifications')
    .select('id, status, reviewer_note, created_at')
    .eq('business_id', businessId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data ? { id: data.id, state: data.status as ReviewState, note: data.reviewer_note, submittedAt: data.created_at } : null;
}

export async function submitBusinessVerification(userId: string, businessId: string, registration: string, photoUri: string | null) {
  const documentPath = photoUri ? await uploadPrivate('business-documents', userId, businessId, photoUri) : null;
  const { error } = await supabase.from('business_verifications').insert({
    business_id: businessId,
    registration_number: registration.trim(),
    document_path: documentPath,
  });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Reviews
// ---------------------------------------------------------------------------

export type ReviewItem = { id: string; rating: number; comment: string | null; createdAt: string; reviewerName: string };

export async function fetchReviewedOrderIds(userId: string): Promise<Set<string>> {
  const { data, error } = await supabase.from('reviews').select('order_id').eq('reviewer_id', userId);
  if (error) throw error;
  return new Set((data ?? []).map((r) => r.order_id as string));
}

export async function submitReview(orderId: string, rating: number, comment: string) {
  const { error } = await supabase.from('reviews').insert({ order_id: orderId, rating, comment: comment.trim() || null });
  if (error) {
    if (error.code === '23505') throw new Error('You have already reviewed this order.');
    throw error;
  }
}

export async function fetchReviewsAbout(userId: string): Promise<ReviewItem[]> {
  const { data, error } = await supabase
    .from('reviews')
    .select('id, rating, comment, created_at, reviewer:profiles!reviews_reviewer_id_fkey(display_name)')
    .eq('reviewee_id', userId)
    .eq('is_hidden', false)
    .order('created_at', { ascending: false })
    .limit(50);
  if (error) throw error;

  const rows = data as unknown as {
    id: string;
    rating: number;
    comment: string | null;
    created_at: string;
    reviewer: { display_name: string } | null;
  }[];
  return rows.map((r) => ({
    id: r.id,
    rating: r.rating,
    comment: r.comment,
    createdAt: r.created_at,
    reviewerName: r.reviewer?.display_name ?? 'Someone',
  }));
}

// ---------------------------------------------------------------------------
// Disputes
// ---------------------------------------------------------------------------

export type DisputeStatus = 'open' | 'awaiting_info' | 'resolved' | 'rejected';

export type Dispute = {
  id: string;
  orderId: string;
  reason: string;
  details: string | null;
  status: DisputeStatus;
  outcome: string | null;
  openedBy: string;
  createdAt: string;
};

export const DISPUTE_STATUS_LABELS: Record<DisputeStatus, string> = {
  open: 'Open',
  awaiting_info: 'We need more information',
  resolved: 'Resolved',
  rejected: 'Closed without action',
};

type RawDispute = {
  id: string;
  order_id: string;
  reason: string;
  details: string | null;
  status: DisputeStatus;
  outcome: string | null;
  opened_by: string;
  created_at: string;
};

const DISPUTE_COLUMNS = 'id, order_id, reason, details, status, outcome, opened_by, created_at';

export function toDispute(r: RawDispute): Dispute {
  return {
    id: r.id,
    orderId: r.order_id,
    reason: r.reason,
    details: r.details,
    status: r.status,
    outcome: r.outcome,
    openedBy: r.opened_by,
    createdAt: r.created_at,
  };
}

export async function openDispute(orderId: string, reason: string, details: string): Promise<void> {
  const { error } = await supabase.rpc('open_dispute', {
    p_order_id: orderId,
    p_reason: reason.trim(),
    p_details: details.trim() || null,
  });
  if (error) throw error;
}

export async function fetchDisputeForOrder(orderId: string): Promise<Dispute | null> {
  const { data, error } = await supabase
    .from('disputes')
    .select(DISPUTE_COLUMNS)
    .eq('order_id', orderId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data ? toDispute(data as RawDispute) : null;
}

export async function fetchDispute(id: string): Promise<Dispute> {
  const { data, error } = await supabase.from('disputes').select(DISPUTE_COLUMNS).eq('id', id).single();
  if (error) throw error;
  return toDispute(data as RawDispute);
}

export type Evidence = { id: string; uploaderId: string; note: string | null; storagePath: string | null; createdAt: string };

export async function fetchEvidence(disputeId: string): Promise<Evidence[]> {
  const { data, error } = await supabase
    .from('dispute_evidence')
    .select('id, uploader_id, note, storage_path, created_at')
    .eq('dispute_id', disputeId)
    .order('created_at', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((e) => ({
    id: e.id as string,
    uploaderId: e.uploader_id as string,
    note: e.note as string | null,
    storagePath: e.storage_path as string | null,
    createdAt: e.created_at as string,
  }));
}

export async function addEvidenceNote(disputeId: string, note: string) {
  const { error } = await supabase.from('dispute_evidence').insert({ dispute_id: disputeId, note: note.trim() });
  if (error) throw error;
}

export async function addEvidencePhoto(userId: string, disputeId: string, photoUri: string) {
  const path = await uploadPrivate('dispute-evidence', userId, disputeId, photoUri);
  const { error } = await supabase.from('dispute_evidence').insert({ dispute_id: disputeId, storage_path: path });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Appeals
// ---------------------------------------------------------------------------

export type AppealTarget = 'listing' | 'user' | 'message' | 'business' | 'review';
export type AppealStatus = 'open' | 'upheld' | 'overturned';

export type Appeal = {
  id: string;
  targetType: AppealTarget;
  targetId: string;
  message: string;
  status: AppealStatus;
  reviewerNote: string | null;
  createdAt: string;
};

export const APPEAL_STATUS_LABELS: Record<AppealStatus, string> = {
  open: 'Waiting for a decision',
  upheld: 'Decision stands',
  overturned: 'Decision changed in your favour',
};

type RawAppeal = {
  id: string;
  target_type: AppealTarget;
  target_id: string;
  message: string;
  status: AppealStatus;
  reviewer_note: string | null;
  created_at: string;
};

const APPEAL_COLUMNS = 'id, target_type, target_id, message, status, reviewer_note, created_at';

export function toAppeal(r: RawAppeal): Appeal {
  return {
    id: r.id,
    targetType: r.target_type,
    targetId: r.target_id,
    message: r.message,
    status: r.status,
    reviewerNote: r.reviewer_note,
    createdAt: r.created_at,
  };
}

export async function submitAppeal(targetType: AppealTarget, targetId: string, message: string) {
  const { error } = await supabase.from('appeals').insert({ target_type: targetType, target_id: targetId, message: message.trim() });
  if (error) throw error;
}

export async function fetchMyAppeals(userId: string, targetId: string): Promise<Appeal[]> {
  const { data, error } = await supabase
    .from('appeals')
    .select(APPEAL_COLUMNS)
    .eq('user_id', userId)
    .eq('target_id', targetId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data as RawAppeal[]).map(toAppeal);
}
