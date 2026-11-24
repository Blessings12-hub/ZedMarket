import { supabase } from '../../lib/supabase';

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

// The database checks who may see what. These just ask. A null business means "my own personal listings".
export const fetchSellerAnalytics = (business: string | null, days: number) =>
  rpc<any>('seller_analytics', { p_business: business, p_days: days });
export const fetchEngagement = (business: string | null, days: number) =>
  rpc<any>('engagement_stats', { p_business: business, p_days: days });
export const fetchListingPerformance = (listing: string, days: number) =>
  rpc<any>('listing_performance', { p_listing: listing, p_days: days });

export type SalesRow = { period: string; orders_completed: number; items_zmw: number | string; delivery_fees_zmw: number | string; total_zmw: number | string };
export const fetchSalesReport = (business: string | null, from: string, to: string, group: string) =>
  rpc<SalesRow[]>('sales_report', { p_business: business, p_from: from, p_to: to, p_group: group });

export type ListingSalesRow = { listing_id: string; title: string; orders_completed: number; items_zmw: number | string };
export const fetchSalesByListing = (business: string | null, from: string, to: string) =>
  rpc<ListingSalesRow[]>('sales_by_listing', { p_business: business, p_from: from, p_to: to });

export const fetchPlatformStats = (days: number) => rpc<any>('platform_stats', { p_days: days });
export const fetchTrustStats = (days: number) => rpc<any>('trust_stats', { p_days: days });
export const fetchFinanceTotals = (from: string, to: string) => rpc<any>('financial_totals', { p_from: from, p_to: to });
