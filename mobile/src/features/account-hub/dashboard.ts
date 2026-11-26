// What the redesigned Account Hub shows at the top: quick tiles with count badges, the "where is my order" strip, one
// highlighted card and the selling invitation. Decided here so it can be tested without a phone.
// Nothing here grants access: the database checks every action again. This only decides what appears.
import { orderPhase, phaseLabel, type CancelKind, type Fulfilment, type OrderPhase, type OrderStatus } from '../../domain/orders';
import type { HubFacts, HubHref, SellerApplicationState } from './hub';

const at = (pathname: string, params?: Record<string, string>): HubHref => ({ pathname, params });

// ----- quick tiles -----
export type Tile = { key: string; label: string; href: HubHref; count: number };

// "9+" keeps a badge small. Zero shows nothing.
export function badgeText(n: number): string | undefined {
  if (!Number.isFinite(n) || n <= 0) return undefined;
  return n > 9 ? '9+' : String(Math.floor(n));
}

// Six tiles, the same for everyone: this is the buyer's hub. Selling lives behind its own door ("Selling" below the
// list), so no selling tile or seller count appears here.
export function quickTiles(f: Pick<HubFacts, 'activeBuying' | 'unreadAlerts'>): Tile[] {
  return [
    { key: 'orders', label: 'Orders', href: at('/purchases'), count: f.activeBuying },
    { key: 'saved', label: 'Saved', href: at('/saved'), count: 0 },
    { key: 'messages', label: 'Messages', href: at('/(tabs)/messages'), count: 0 },
    { key: 'alerts', label: 'Alerts', href: at('/alerts'), count: f.unreadAlerts },
    { key: 'reviews', label: 'Reviews', href: at('/account/reviews'), count: 0 },
    { key: 'support', label: 'Help', href: at('/support'), count: 0 },
  ];
}

// ----- where is my order -----
export type StripOrder = { id: string; title: string; status: OrderStatus; cancelKind: CancelKind | null; handedOverAt: string | null; fulfilment: Fulfilment };
export const STRIP_STEPS = ['Requested', 'Confirmed', 'Handed over', 'Done'] as const;
export type StripItem = { id: string; title: string; label: string; step: number; steps: number; needsYou: boolean; problem: boolean };

const ACTIVE: OrderPhase[] = ['requested', 'confirmed', 'handed_over', 'disputed'];
const STEP: Partial<Record<OrderPhase, number>> = { requested: 0, confirmed: 1, handed_over: 2, disputed: 1 };

// Open purchases only, most urgent first (the ones waiting for the buyer), then in the order given. Finished,
// cancelled, declined and expired orders are not "in progress", so they do not appear.
export function orderStrip(orders: StripOrder[], max = 5): { items: StripItem[]; more: number } {
  const open = orders
    .map((o) => ({ o, phase: orderPhase(o) }))
    .filter(({ phase }) => ACTIVE.includes(phase))
    .map(({ o, phase }): StripItem => ({
      id: o.id,
      title: o.title,
      label: phaseLabel(phase, 'buyer', o.fulfilment),
      step: STEP[phase] ?? 0,
      steps: STRIP_STEPS.length,
      needsYou: phase === 'handed_over',
      problem: phase === 'disputed',
    }));
  const sorted = [...open.filter((i) => i.needsYou), ...open.filter((i) => !i.needsYou)];
  return { items: sorted.slice(0, max), more: Math.max(0, sorted.length - max) };
}

// ----- one highlighted card -----
export type Nudge = { key: 'email' | 'profile'; title: string; body: string; cta: string; href: HubHref };

// The most useful next step for this person, or nothing. Only one is ever shown, so the page stays calm.
export function profileNudge(p: { emailConfirmed: boolean; hasAvatar: boolean; hasBio: boolean }): Nudge | null {
  if (!p.emailConfirmed) {
    return { key: 'email', title: 'Confirm your email', body: 'Sellers and our team can trust you more, and you will not miss order updates.', cta: 'Open security', href: at('/settings/security') };
  }
  if (!p.hasAvatar || !p.hasBio) {
    return { key: 'profile', title: 'Complete your profile', body: 'A photo and a short line about you help sellers feel safe dealing with you.', cta: 'Edit profile', href: at('/profile/edit') };
  }
  return null;
}

// ----- selling invitation -----
export type SellingBanner = {
  title: string;
  body: string;
  cta: string;
  badge?: string;
  href: HubHref;
  // Shown only when the person has no business yet.
  secondary?: { title: string; href: HubHref };
};

const APPLICATION: Partial<Record<SellerApplicationState, { cta: string; badge: string }>> = {
  draft: { cta: 'Continue your application', badge: 'Draft' },
  submitted: { cta: 'See your application', badge: 'Sent' },
  under_review: { cta: 'See your application', badge: 'In review' },
  additional_information_required: { cta: 'Answer the team', badge: 'Action needed' },
  rejected: { cta: 'See the reason', badge: 'Not approved' },
};

// Selling is opt-in: only a buyer gets an invitation. Approved, suspended and revoked sellers have their own section.
export function sellingBanner(f: Pick<HubFacts, 'sellerStatus' | 'sellerApplication' | 'businesses'>): SellingBanner | null {
  if (f.sellerStatus !== 'none') return null;
  const state = f.sellerApplication ? APPLICATION[f.sellerApplication] : undefined;
  return {
    title: 'Have something to sell?',
    body: 'ZedMarket is a place to buy first. To sell, apply and our team will verify you. Selling tools appear once you are approved.',
    cta: state?.cta ?? 'Become a seller',
    badge: state?.badge,
    href: at('/verify/seller'),
    secondary: f.businesses.length === 0 ? { title: 'Register a business', href: at('/business/manage') } : undefined,
  };
}
