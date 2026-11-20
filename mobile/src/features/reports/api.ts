import { supabase } from '../../lib/supabase';

export type ReportTarget = 'listing' | 'user' | 'message' | 'business' | 'review';
export type ReportReason =
  | 'scam_or_fake'
  | 'prohibited_item'
  | 'counterfeit_or_stolen'
  | 'harassment'
  | 'wrong_details'
  | 'other';

export const REPORT_REASONS: { value: ReportReason; label: string }[] = [
  { value: 'scam_or_fake', label: 'Scam or fake listing' },
  { value: 'prohibited_item', label: 'Item that is not allowed' },
  { value: 'counterfeit_or_stolen', label: 'Counterfeit or stolen goods' },
  { value: 'harassment', label: 'Harassment or abuse' },
  { value: 'wrong_details', label: 'Wrong price or details' },
  { value: 'other', label: 'Something else' },
];

export async function submitReport(target: ReportTarget, targetId: string, reason: ReportReason, details: string) {
  const { error } = await supabase.from('reports').insert({
    target_type: target,
    target_id: targetId,
    reason,
    details: details.trim() || null,
  });
  if (error) throw error;
}

export async function blockUser(userId: string) {
  const { error } = await supabase.from('blocks').insert({ blocked_id: userId });
  if (error) throw error;
}
