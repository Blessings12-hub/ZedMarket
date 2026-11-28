// Promoted listings, arranged by hand (migration 0040). The seller asks, pays the ZedMarket team outside the app,
// and staff approve with the payment reference. There is no automatic payment.

export const PROMOTION_DAYS = [7, 14, 30] as const;
export type PromotionDays = (typeof PROMOTION_DAYS)[number];

export type PromotionPrices = { d7: number; d14: number; d30: number };

export function priceFor(prices: PromotionPrices, days: PromotionDays): number {
  return days === 7 ? prices.d7 : days === 14 ? prices.d14 : prices.d30;
}

export type PromotionStatus = 'requested' | 'approved' | 'rejected' | 'cancelled';

const STATUS_TEXT: Record<PromotionStatus, string> = {
  requested: 'Waiting for the ZedMarket team',
  approved: 'Approved',
  rejected: 'Not approved',
  cancelled: 'Cancelled',
};

export function promotionStatusText(status: string): string {
  return STATUS_TEXT[status as PromotionStatus] ?? status;
}

// Staff must type a payment reference to approve, and a reason to reject.
export function decisionError(approve: boolean, note: string): string | null {
  const n = note.trim();
  if (approve) return n.length >= 3 ? null : 'Type the payment reference (at least 3 characters).';
  return n.length > 0 ? null : 'Say why the request is not approved.';
}

export function toPrices(raw: unknown): PromotionPrices | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const d7 = Number(r.d7), d14 = Number(r.d14), d30 = Number(r.d30);
  return [d7, d14, d30].every((n) => Number.isFinite(n) && n >= 0) ? { d7, d14, d30 } : null;
}

export type MyPromotion = {
  id: string; listingId: string; title: string; days: number; price: number; status: PromotionStatus; decisionNote: string | null;
  createdAt: string; liveUntil: string | null;
};

export type QueuedPromotion = { id: string; listingId: string; title: string; days: number; price: number; sellerName: string; createdAt: string };

type Row = Record<string, unknown>;
export const toMyPromotions = (raw: unknown): MyPromotion[] =>
  (Array.isArray(raw) ? (raw as Row[]) : []).map((r) => ({
    id: String(r.id), listingId: String(r.listing_id), title: String(r.title ?? ''), days: Number(r.days), price: Number(r.price_zmw),
    status: r.status as PromotionStatus, decisionNote: (r.decision_note as string) ?? null, createdAt: String(r.created_at), liveUntil: (r.live_until as string) ?? null,
  }));
export const toQueue = (raw: unknown): QueuedPromotion[] =>
  (Array.isArray(raw) ? (raw as Row[]) : []).map((r) => ({
    id: String(r.id), listingId: String(r.listing_id), title: String(r.title ?? ''), days: Number(r.days), price: Number(r.price_zmw),
    sellerName: String(r.seller_name ?? ''), createdAt: String(r.created_at),
  }));
