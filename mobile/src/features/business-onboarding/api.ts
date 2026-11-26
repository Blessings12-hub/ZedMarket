import { supabase } from '../../lib/supabase';
import type { Party, BizForm } from './domain';
import { loadMine, type MyBusinessApplication } from './mine';

export type { MyBusinessApplication } from './mine';

// Every call goes through here so the real error is always logged. The screens show a readable message from
// friendlyError; the log keeps the technical one for whoever is fixing it.
async function rpc<T>(name: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    console.error(`[business] ${name} failed`, error);
    throw error;
  }
  return data as T;
}

// Never returns a made-up empty answer for a failed call: a failure throws, and the screen shows it with a retry.
export const fetchMine = (businessId: string): Promise<MyBusinessApplication> => loadMine(() => supabase.rpc('business_application_mine', { p_business: businessId }));
export const fetchOptions = async () => {
  const [c, l] = await Promise.all([
    supabase.from('categories').select('id, name').eq('is_active', true).order('name'),
    supabase.from('locations').select('id, town, area').order('town'),
  ]);
  if (c.error) throw c.error;
  if (l.error) throw l.error;
  return { categories: (c.data ?? []) as { id: number; name: string }[], locations: (l.data ?? []) as { id: number; town: string; area: string | null }[] };
};
export const fetchAgreement = async (): Promise<{ version: number; title: string; body: string } | null> => {
  const rows = await rpc<{ version: number; title: string; body: string }[] | null>('seller_agreement_current');
  return Array.isArray(rows) ? rows[0] ?? null : null;
};
export const acceptAgreement = (version: number) => rpc<void>('seller_agreement_accept', { p_version: version });
export const saveApplication = (businessId: string, f: Partial<BizForm>) =>
  rpc<string>('business_application_save', {
    p_business: businessId,
    p_data: { ...f, expected_catalogue_size: f.expected_catalogue_size ? Number(f.expected_catalogue_size) : undefined,
              years_trading: f.years_trading ? Number(f.years_trading) : undefined, pacra_registered_on: f.pacra_registered_on || undefined },
  });
export const setParties = (appId: string, parties: Party[]) =>
  rpc<void>('business_application_set_parties', {
    p_id: appId,
    p_parties: parties.map((p) => ({ kind: p.kind, full_name: p.full_name, nationality: p.nationality, ownership_pct: p.kind === 'beneficial_owner' ? Number(p.ownership_pct) : null, id_number: p.id_number })),
  });
export const setBranches = (appId: string, branches: { name: string; address: string; phone?: string }[]) => rpc<void>('business_application_set_branches', { p_id: appId, p_branches: branches });
export const setPermits = (appId: string, permits: { permit_type: string; permit_number?: string; issuer?: string; expires_on?: string }[]) => rpc<void>('business_application_set_permits', { p_id: appId, p_permits: permits });
export const submitApplication = (appId: string) => rpc<void>('business_application_submit', { p_id: appId });
export const withdrawApplication = (appId: string) => rpc<void>('business_application_withdraw', { p_id: appId });
export const respondToRequest = (id: string, text: string) => rpc<void>('business_application_respond', { p_request: id, p_response: text });

// Same pattern as the seller flow: upload into the owner's own folder, then register so the database checks the real file.
export async function uploadDocument(userId: string, appId: string, kind: string, pick: () => Promise<string | null>): Promise<boolean> {
  const uri = await pick();
  if (!uri) return false;
  const body = await (await fetch(uri)).arrayBuffer();
  const path = `${userId}/business/${kind}-${Date.now()}.jpg`;
  const up = await supabase.storage.from('business-documents').upload(path, body, { contentType: 'image/jpeg', upsert: false });
  if (up.error) throw up.error;
  await rpc<string>('verification_register_document', {
    p_subject_type: 'business_application', p_subject_id: appId, p_kind: kind, p_bucket: 'business-documents', p_path: path,
  });
  return true;
}

// ----- staff -----
export type BizQueueRow = {
  id: string; business_id: string; business_name: string; route: string; applicant_name: string; status: string; risk_level: string;
  escalated: boolean; awaiting_second: boolean; assigned_to: string | null; assigned_name: string | null; overdue: boolean; pending_documents: number; mine: boolean;
};
export const fetchQueue = (queue: string) => rpc<BizQueueRow[]>('business_verification_queue', { p_queue: queue, p_limit: 50, p_offset: 0 });
export const fetchDetail = (id: string) => rpc<Record<string, any>>('business_application_detail', { p_id: id });
export const fetchPrivate = (id: string) => rpc<{ tpin: string; rep_id_number: string; parties: { full_name: string; kind: string; id_number: string }[] }>('business_application_private_details', { p_id: id });
export const claim = (id: string) => rpc<void>('business_application_claim', { p_id: id });
export const requestInfo = (id: string, message: string, kinds: string[]) => rpc<string>('business_application_request_info', { p_id: id, p_message: message, p_kinds: kinds });
export const recordInterview = (id: string, channel: string, outcome: string, answers: { q: string; a: string }[], notes: string) =>
  rpc<string>('business_application_record_interview', { p_id: id, p_channel: channel, p_outcome: outcome, p_answers: answers, p_notes: notes || null });
export const recordCheck = (id: string, check: string, result: string, notes: string) => rpc<string>('business_application_record_check', { p_id: id, p_check: check, p_result: result, p_notes: notes });
export const escalate = (id: string, reason: string) => rpc<void>('business_application_escalate', { p_id: id, p_reason: reason });
export const decide = (id: string, decision: 'approve' | 'reject', reason: string) => rpc<string>('business_application_decide', { p_id: id, p_decision: decision, p_reason: reason });
export const suspend = (id: string, reason: string, revoke: boolean) => rpc<void>('business_application_suspend', { p_id: id, p_reason: reason, p_revoke: revoke });
export const reinstate = (id: string, reason: string) => rpc<void>('business_application_reinstate', { p_id: id, p_reason: reason });
