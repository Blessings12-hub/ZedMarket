// The top of the Business centre: what needs the shop today, a setup checklist for new shops, and a short sales summary.
// Only decides what to show. The database checks every action again.
import { roleCan, type BusinessPermission, type BusinessRole } from '../../domain/business';

export type BusinessFacts = {
  requested: number; // orders waiting for the shop to accept
  confirmed: number; // accepted, not finished
  lowStock: number;
  outOfStock: number;
  disputed: number;
};

export type AttentionTile = { key: 'orders' | 'in-progress' | 'stock' | 'disputes'; label: string; count: number; href: 'orders' | 'inventory'; urgent: boolean };

const can = (role: BusinessRole, p: BusinessPermission) => roleCan(role, p);
const whole = (n: number) => (Number.isFinite(n) && n > 0 ? Math.floor(n) : 0);

// Tiles with something in them, most pressing first. People who cannot work orders or stock do not see those tiles.
export function attentionTiles(role: BusinessRole, f: BusinessFacts): AttentionTile[] {
  const tiles: AttentionTile[] = [];
  if (can(role, 'manage_orders')) {
    tiles.push({ key: 'orders', label: 'Orders to answer', count: whole(f.requested), href: 'orders', urgent: true });
    tiles.push({ key: 'disputes', label: 'In dispute', count: whole(f.disputed), href: 'orders', urgent: true });
    tiles.push({ key: 'in-progress', label: 'In progress', count: whole(f.confirmed), href: 'orders', urgent: false });
  }
  if (can(role, 'manage_inventory')) {
    tiles.push({ key: 'stock', label: 'Low or out of stock', count: whole(f.lowStock) + whole(f.outOfStock), href: 'inventory', urgent: whole(f.outOfStock) > 0 });
  }
  return tiles.filter((t) => t.count > 0);
}

export type SetupFacts = { branches: number; products: number; catalogues: number; verified: boolean };
export type SetupStep = { key: 'branch' | 'products' | 'catalogue' | 'verify'; title: string; hint: string; done: boolean; route: string };
export const PRODUCTS_GOAL = 3;

// Only steps the app can actually do are listed (logo and description cannot be edited in the app yet).
// Steps are limited to what this person is allowed to do. Verification is the owner's job only.
export function setupChecklist(role: BusinessRole, f: SetupFacts): { steps: SetupStep[]; done: number; total: number; complete: boolean } {
  const steps: SetupStep[] = [];
  if (can(role, 'manage_branches')) steps.push({ key: 'branch', title: 'Add a branch', hint: 'Tell buyers where to collect.', done: f.branches > 0, route: 'branches' });
  if (can(role, 'manage_listings')) steps.push({ key: 'products', title: `Post ${PRODUCTS_GOAL} products`, hint: 'A shop with a few products gets more visits.', done: f.products >= PRODUCTS_GOAL, route: 'products' });
  if (can(role, 'manage_catalogues')) steps.push({ key: 'catalogue', title: 'Group products in a catalogue', hint: 'Makes your storefront easy to browse.', done: f.catalogues > 0, route: 'catalogues' });
  if (role === 'owner') steps.push({ key: 'verify', title: 'Verify your business', hint: 'Needed for the verified badge.', done: f.verified, route: 'verify' });
  const done = steps.filter((s) => s.done).length;
  return { steps, done, total: steps.length, complete: steps.length === 0 || done === steps.length };
}

export type SalesInput = { periodDays: number; completedOrders: number; completedValue: number; ordersReceived: number; topListings: { id: string; title: string; completed: number }[] };
export type SalesSummary = { periodLabel: string; revenue: string; completedOrders: number; ordersReceived: number; top: { id: string; title: string; completed: number }[]; empty: boolean };

// Only people who may view analytics get this; everyone else gets null. Top products must have at least one sale.
export function salesSummary(role: BusinessRole, a: SalesInput | null): SalesSummary | null {
  if (!a || !can(role, 'view_analytics')) return null;
  const top = a.topListings.filter((t) => t.completed > 0).slice(0, 3).map((t) => ({ id: t.id, title: t.title, completed: t.completed }));
  return {
    periodLabel: a.periodDays === 1 ? 'today' : `last ${a.periodDays} days`,
    revenue: `K${Math.round(Number.isFinite(a.completedValue) ? a.completedValue : 0).toLocaleString('en-US')}`,
    completedOrders: whole(a.completedOrders),
    ordersReceived: whole(a.ordersReceived),
    top,
    empty: whole(a.ordersReceived) === 0 && whole(a.completedOrders) === 0,
  };
}

// The database's "low" list also contains items that are completely out (0 is below any warning level).
// Count each item once: out of stock, or low but still in stock.
export function stockCounts(low: { listingId: string }[], out: { listingId: string }[]): { lowStock: number; outOfStock: number } {
  const outIds = new Set(out.map((r) => r.listingId));
  return { outOfStock: outIds.size, lowStock: new Set(low.map((r) => r.listingId).filter((id) => !outIds.has(id))).size };
}
