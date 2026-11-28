import { toMyPromotions, toPrices, toQueue, type MyPromotion, type PromotionPrices, type QueuedPromotion } from '../../domain/promotion';
import { supabase } from '../../lib/supabase';

export async function fetchPromotionPrices(): Promise<PromotionPrices | null> {
  const { data, error } = await supabase.rpc('promotion_prices');
  return error ? null : toPrices(data);
}

export async function requestPromotion(listingId: string, days: number): Promise<void> {
  const { error } = await supabase.rpc('promotion_request', { p_listing: listingId, p_days: days });
  if (error) throw error;
}

export async function cancelPromotionRequest(id: string): Promise<void> {
  const { error } = await supabase.rpc('promotion_cancel', { p_request: id });
  if (error) throw error;
}

export async function fetchMyPromotions(): Promise<MyPromotion[]> {
  const { data, error } = await supabase.rpc('promotion_my');
  if (error) throw error;
  return toMyPromotions(data);
}

export async function fetchPromotionQueue(): Promise<QueuedPromotion[]> {
  const { data, error } = await supabase.rpc('promotion_queue');
  if (error) throw error;
  return toQueue(data);
}

export async function decidePromotion(id: string, approve: boolean, note: string): Promise<void> {
  const { error } = await supabase.rpc('promotion_decide', { p_request: id, p_approve: approve, p_note: note });
  if (error) throw error;
}

export async function endPromotion(listingId: string, reason: string): Promise<void> {
  const { error } = await supabase.rpc('promotion_end', { p_listing: listingId, p_reason: reason });
  if (error) throw error;
}
