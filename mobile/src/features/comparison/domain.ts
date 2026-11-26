// Product comparison: pure logic, no network. The database decides which listings may be shown.
export const MAX_COMPARE = 4;
export type CompareItem = {
  id: string; title: string; price: number; condition: string; warranty: string | null; returnPolicy: string | null; category: string;
  town: string | null; area: string | null; sellerName: string; sellerLevel: string; rating: number | null; reviews: number; completedOrders: number; image: string | null;
};
export type Comparison = { items: CompareItem[]; missing: string[]; sameCategory: boolean };

const num = (v: unknown): number => { const x = Number(v); return Number.isFinite(x) ? x : 0; };
const str = (v: unknown): string | null => (typeof v === 'string' && v.trim() ? v : null);

export function normalizeComparison(v: any): Comparison {
  if (!v || typeof v !== 'object') throw new Error('The comparison came back empty.');
  const items: CompareItem[] = (Array.isArray(v.items) ? v.items : []).map((r: any) => ({
    id: String(r.id), title: String(r.title ?? ''), price: num(r.price), condition: String(r.condition ?? ''), warranty: str(r.warranty), returnPolicy: str(r.return_policy),
    category: String(r.category ?? ''), town: str(r.town), area: str(r.area), sellerName: String(r.seller_name ?? ''), sellerLevel: String(r.seller_level ?? 'unverified'),
    rating: r.rating == null ? null : num(r.rating), reviews: num(r.reviews), completedOrders: num(r.completed_orders), image: str(r.image),
  }));
  return { items, missing: Array.isArray(v.missing) ? v.missing.map(String) : [], sameCategory: v.same_category !== false };
}

// Adds or removes an id. Never more than MAX_COMPARE; the caller shows `full` so a tap is never silently ignored.
export function toggleCompare(ids: string[], id: string): { ids: string[]; full: boolean } {
  if (ids.includes(id)) return { ids: ids.filter((x) => x !== id), full: false };
  if (ids.length >= MAX_COMPARE) return { ids, full: true };
  return { ids: [...ids, id], full: false };
}

export const cheapestId = (items: CompareItem[]): string | null =>
  items.length < 2 ? null : items.reduce((a, b) => (b.price < a.price ? b : a)).id;
export const canCompare = (ids: string[]): boolean => ids.length >= 2 && ids.length <= MAX_COMPARE;
