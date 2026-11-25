import type { Moderation, TrackerStatus } from '../../domain/sellerTools';
import { supabase } from '../../lib/supabase';

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export type TrackedListing = {
  id: string; title: string; price: number; status: TrackerStatus; moderation: Moderation; note: string | null;
  photos: number; tracked: boolean; quantity: number | null; sku: string | null; views30: number; saves: number; orders: number; updatedAt: string;
};
export type TimelineEntry = { status: TrackerStatus; moderation: Moderation; note: string | null; byStaff: boolean; at: string };

export async function fetchTracker(business: string | null, status: string, search: string): Promise<TrackedListing[]> {
  const rows = await rpc<any[]>('seller_listings', { p_business: business, p_status: status, p_search: search || null, p_limit: 100, p_offset: 0 });
  return (rows ?? []).map((r) => ({
    id: r.listing_id, title: r.title, price: Number(r.price_zmw), status: r.status, moderation: r.moderation_status, note: r.moderation_note,
    photos: Number(r.photos), tracked: r.tracked, quantity: r.quantity, sku: r.sku, views30: Number(r.views_30d), saves: Number(r.saves),
    orders: Number(r.orders_total), updatedAt: r.updated_at,
  }));
}

export async function fetchTimeline(listing: string): Promise<TimelineEntry[]> {
  const rows = await rpc<any[]>('listing_timeline', { p_listing: listing });
  return (rows ?? []).map((r) => ({ status: r.status, moderation: r.moderation_status, note: r.note, byStaff: r.by_staff, at: r.created_at }));
}

export const duplicateListing = (listing: string, title?: string, sku?: string, quantity?: number) =>
  rpc<string>('duplicate_listing', { p_listing: listing, p_title: title ?? null, p_sku: sku ?? null, p_quantity: quantity ?? null });

export const bulkPrices = (listings: string[], mode: 'set' | 'percent' | 'amount', value: number) =>
  rpc<any[]>('bulk_update_prices', { p_listings: listings, p_mode: mode, p_value: value });

export const bulkStock = (items: { listing_id: string; mode: 'set' | 'adjust'; value: number }[]) =>
  rpc<any[]>('bulk_update_stock', { p_items: items });

export type Photo = { id: string; path: string };
export async function fetchPhotos(listing: string): Promise<Photo[]> {
  const { data, error } = await supabase.from('listing_images').select('id, storage_path, position').eq('listing_id', listing).order('position');
  if (error) throw error;
  return (data ?? []).map((r: any) => ({ id: r.id, path: r.storage_path }));
}
export const reorderPhotos = (listing: string, ids: string[]) => rpc('reorder_listing_images', { p_listing: listing, p_ids: ids });
