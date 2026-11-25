// Seller tools: what a listing's state means to the seller, and the price/stock maths shown before the server applies it.
// The database does the real work and the real checks; this is only the preview and the wording.

export type TrackerStatus = 'draft' | 'active' | 'sold' | 'unavailable' | 'removed';
export type Moderation = 'pending' | 'approved' | 'rejected';

export function sellerState(status: TrackerStatus, moderation: Moderation): { label: string; tone: 'good' | 'wait' | 'bad' | 'quiet'; next: string } {
  if (status === 'draft') return { label: 'Draft', tone: 'quiet', next: 'Add photos and publish when it is ready.' };
  if (status === 'sold') return { label: 'Sold', tone: 'quiet', next: 'Nothing to do.' };
  if (status === 'unavailable') return { label: 'Paused', tone: 'wait', next: 'It comes back when you restock.' };
  if (status === 'removed') return { label: 'Removed', tone: 'bad', next: 'A moderator removed it.' };
  if (moderation === 'pending') return { label: 'Waiting for review', tone: 'wait', next: 'A moderator will check it. You will be notified.' };
  if (moderation === 'rejected') return { label: 'Not approved', tone: 'bad', next: 'Read the reason, fix the listing, or appeal.' };
  return { label: 'Live', tone: 'good', next: 'Buyers can see it.' };
}

export const FILTERS: { key: string; label: string }[] = [
  { key: 'all', label: 'All' }, { key: 'live', label: 'Live' }, { key: 'review', label: 'In review' },
  { key: 'rejected', label: 'Not approved' }, { key: 'draft', label: 'Drafts' }, { key: 'paused', label: 'Paused' }, { key: 'sold', label: 'Sold' },
];

export type PriceMode = 'set' | 'percent' | 'amount';

export function newPrice(old: number, mode: PriceMode, value: number): number | null {
  if (!Number.isFinite(value)) return null;
  const raw = mode === 'set' ? value : mode === 'percent' ? old * (1 + value / 100) : old + value;
  const rounded = Math.round(raw * 100) / 100;
  return rounded > 0 && rounded < 100_000_000 ? rounded : null;
}

export function parseNumber(text: string): number | null {
  const t = text.trim().replace(/,/g, '');
  if (!/^-?\d+(\.\d+)?$/.test(t)) return null;
  return Number(t);
}

export function parseWhole(text: string): number | null {
  const n = parseNumber(text);
  return n !== null && Number.isInteger(n) ? n : null;
}

export function toggle(selected: string[], id: string, max = 200): string[] {
  if (selected.includes(id)) return selected.filter((s) => s !== id);
  return selected.length >= max ? selected : [...selected, id];
}

export function movePhoto<T>(items: T[], index: number, delta: -1 | 1): T[] {
  const to = index + delta;
  if (index < 0 || index >= items.length || to < 0 || to >= items.length) return items;
  const next = items.slice();
  const [moved] = next.splice(index, 1);
  next.splice(to, 0, moved as T);
  return next;
}
