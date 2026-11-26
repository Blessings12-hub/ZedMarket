import { supabase } from '../../lib/supabase';

export type PhotoFlag = { id: string; status: string; listingId: string; title: string; seller: string; otherListingId: string; otherTitle: string; otherSeller: string; at: string; note: string | null };

export async function fetchFlags(status: 'open' | 'confirmed' | 'dismissed'): Promise<PhotoFlag[]> {
  const { data, error } = await supabase.rpc('image_flag_queue', { p_status: status, p_limit: 50, p_offset: 0 });
  if (error) { console.error('[photos] image_flag_queue failed', error); throw error; }
  if (!Array.isArray(data)) return [];
  return data.map((r: any) => ({ id: r.id, status: r.status, listingId: r.listing_id, title: r.listing_title ?? '', seller: r.seller_name ?? '', otherListingId: r.other_listing_id,
    otherTitle: r.other_title ?? '', otherSeller: r.other_seller_name ?? '', at: r.created_at, note: r.note ?? null }));
}
export async function resolveFlag(id: string, decision: 'dismiss' | 'confirm', note: string): Promise<void> {
  const { error } = await supabase.rpc('image_flag_resolve', { p_id: id, p_decision: decision, p_note: note || null });
  if (error) { console.error('[photos] image_flag_resolve failed', error); throw error; }
}
