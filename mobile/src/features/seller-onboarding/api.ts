import { supabase } from '../../lib/supabase';
import { pickOnePhoto } from '../trust/api';
import type { Form } from './domain';
import { loadMine, type MyApplication } from './mine';

export type { MyApplication } from './mine';

// Every call goes through here so the real error is always logged. The screens show a readable message from
// friendlyError; the log keeps the technical one for whoever is fixing it.
async function rpc<T>(name: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    console.error(`[seller] ${name} failed`, error);
    throw error;
  }
  return data as T;
}

// Never returns a made-up empty answer for a failed call: a failure throws, and the screen shows it with a retry.
export const fetchMine = (): Promise<MyApplication> => loadMine(() => supabase.rpc('seller_application_mine'));
export const fetchAgreement = async (): Promise<{ version: number; title: string; body: string } | null> => {
  const rows = await rpc<{ version: number; title: string; body: string }[] | null>('seller_agreement_current');
  return Array.isArray(rows) ? rows[0] ?? null : null;
};
export const saveApplication = (f: Partial<Form>) =>
  rpc<string>('seller_application_save', {
    p_data: { ...f, expected_catalogue_size: f.expected_catalogue_size ? Number(f.expected_catalogue_size) : undefined },
  });
export const acceptAgreement = (version: number) => rpc<void>('seller_agreement_accept', { p_version: version });
export const submitApplication = () => rpc<void>('seller_application_submit');
export const withdrawApplication = () => rpc<void>('seller_application_withdraw');
// Closes my selling account (I stay a buyer). The database refuses while orders are open and says which ones.
export const closeSellerAccount = (reason?: string) => rpc<void>('seller_account_close', { p_reason: reason ?? null });
export const respondToRequest = (id: string, text: string) => rpc<void>('seller_application_respond', { p_request: id, p_response: text });

// Upload into the person's own folder of the private bucket, then register it so the database checks the real file.
export async function uploadDocument(userId: string, appId: string, kind: string): Promise<boolean> {
  const uri = await pickOnePhoto();
  if (!uri) return false;
  const body = await (await fetch(uri)).arrayBuffer();
  const path = `${userId}/seller/${kind}-${Date.now()}.jpg`;
  const up = await supabase.storage.from('identity-documents').upload(path, body, { contentType: 'image/jpeg', upsert: false });
  if (up.error) throw up.error;
  await rpc<string>('verification_register_document', {
    p_subject_type: 'seller_application', p_subject_id: appId, p_kind: kind, p_bucket: 'identity-documents', p_path: path,
  });
  return true;
}

export async function fetchOptions() {
  const [c, l] = await Promise.all([
    supabase.from('categories').select('id, name').order('name'),
    supabase.from('locations').select('id, area, town').order('town').order('area', { nullsFirst: true }),
  ]);
  // A failed list is an error the screen shows with a retry, not an empty list that quietly blocks the form.
  if (c.error) {
    console.error('[seller] loading categories failed', c.error);
    throw c.error;
  }
  if (l.error) {
    console.error('[seller] loading locations failed', l.error);
    throw l.error;
  }
  return { categories: (c.data ?? []) as { id: number; name: string }[], locations: (l.data ?? []) as { id: number; area: string | null; town: string }[] };
}

// ----- staff -----
export type QueueRow = {
  id: string; applicant_id: string; applicant_name: string; status: string; risk_level: string; escalated: boolean; awaiting_second: boolean;
  assigned_to: string | null; assigned_name: string | null; submitted_at: string | null; due_at: string | null; overdue: boolean;
  pending_documents: number; mine: boolean;
};
export const fetchQueue = (queue: string) => rpc<QueueRow[]>('verification_queue', { p_queue: queue, p_limit: 50, p_offset: 0 });
export const fetchDetail = (id: string) => rpc<Record<string, any>>('seller_application_detail', { p_id: id });
export const fetchPrivate = async (id: string) => (await rpc<{ id_number: string; residential_address: string }[]>('seller_application_private_details', { p_id: id }))[0];
export const claim = (id: string) => rpc<void>('seller_application_claim', { p_id: id });
export const requestInfo = (id: string, message: string, kinds: string[]) => rpc<string>('seller_application_request_info', { p_id: id, p_message: message, p_kinds: kinds });
export const recordInterview = (id: string, channel: string, outcome: string, answers: { q: string; a: string }[], notes: string) =>
  rpc<string>('seller_application_record_interview', { p_id: id, p_channel: channel, p_outcome: outcome, p_answers: answers, p_notes: notes || null });
export const escalate = (id: string, reason: string) => rpc<void>('seller_application_escalate', { p_id: id, p_reason: reason });
export const decide = (id: string, decision: 'approve' | 'reject', reason: string) => rpc<string>('seller_application_decide', { p_id: id, p_decision: decision, p_reason: reason });
export const suspend = (id: string, reason: string, revoke: boolean) => rpc<void>('seller_application_suspend', { p_id: id, p_reason: reason, p_revoke: revoke });
export const reinstate = (id: string, reason: string) => rpc<void>('seller_application_reinstate', { p_id: id, p_reason: reason });
export const reviewDocument = (doc: string, accept: boolean, note: string) => rpc<void>('verification_review_document', { p_document: doc, p_accept: accept, p_note: note || null });

// Documents are opened only through the Edge Function: it asks the database (audited, support + two-factor, scan clean)
// and only then signs a link that lasts a minute. There is no direct storage read for staff.
export async function openDocument(doc: string): Promise<string> {
  const { data, error } = await supabase.functions.invoke('verification-document-url', { body: { document_id: doc } });
  if (error) throw error;
  return (data as { url: string }).url;
}
