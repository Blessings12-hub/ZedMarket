// What the Account Hub shows, decided in one place so it can be tested without a phone.
// Nothing here grants access: the database checks every action again. This only decides which buttons appear.
import { roleCan, type BusinessRole } from '../../domain/business';

export type HubHref = { pathname: string; params?: Record<string, string> };
export type HubItem = { key: string; title: string; subtitle?: string; href: HubHref; badge?: string };
export type HubSection = { key: string; title: string; items: HubItem[] };

export type HubBusiness = { id: string; name: string; slug: string; role: BusinessRole; verified: boolean };

export type HubFacts = {
  isStaff: boolean;
  // True once the person has started selling (verified identity, or listings they already posted). Buyers are never
  // shown selling tools. The database still decides what a seller may do.
  isSeller: boolean;
  paymentsOn: boolean;
  unreadNotifications: number;
  unreadAlerts: number;
  openRequestsToMe: number; // orders waiting for my answer as a seller
  activeBuying: number; // my open purchases
  listings: { live: number; waiting: number; total: number };
  businesses: HubBusiness[];
  context: 'personal' | string; // 'personal' or a business id
};

const at = (pathname: string, params?: Record<string, string>): HubHref => ({ pathname, params });

function count(n: number, noun: string): string | undefined {
  return n > 0 ? `${n} ${noun}` : undefined;
}

export function purchasesSection(f: HubFacts): HubSection {
  const items: HubItem[] = [
    { key: 'orders', title: 'My orders', subtitle: 'Your purchases and their status', href: at('/orders'), badge: count(f.activeBuying, 'open') },
    { key: 'saved', title: 'Saved products', subtitle: 'Items you have saved', href: at('/saved') },
    { key: 'alerts', title: 'Saved searches and alerts', subtitle: 'Get told when a matching item is posted', href: at('/alerts'), badge: count(f.unreadAlerts, 'new') },
    { key: 'reviews', title: 'My reviews', subtitle: 'Reviews you wrote and reviews about you', href: at('/account/reviews') },
  ];
  if (f.paymentsOn) items.push({ key: 'payments', title: 'Payments', subtitle: 'Payments made through ZedMarket', href: at('/payments') });
  return { key: 'purchases', title: 'My purchases', items };
}

export function sellingSection(f: HubFacts): HubSection {
  const mine = f.listings.total;
  const subtitle = mine === 0 ? 'You have not posted anything yet' : `${f.listings.live} live, ${f.listings.waiting} waiting for review`;
  return {
    key: 'selling',
    title: 'My selling account',
    items: [
      { key: 'seller-dashboard', title: 'Seller dashboard', subtitle: 'Views, sales and replies', href: at('/analytics') },
      { key: 'my-products', title: 'My products', subtitle, href: at('/account/listings') },
      { key: 'post', title: 'Post a listing', subtitle: 'Goes to review before it is shown', href: at('/(tabs)/sell') },
      { key: 'coverage-areas', title: 'Where I deliver', subtitle: 'Limit delivery to certain places', href: at('/delivery/areas') },
      { key: 'selling-orders', title: 'Selling orders', subtitle: 'Requests from buyers', href: at('/orders'), badge: count(f.openRequestsToMe, 'to answer') },
      { key: 'enquiries', title: 'Customer enquiries', subtitle: 'Chats with interested buyers', href: at('/(tabs)/messages') },
      { key: 'seller-verification', title: 'Seller verification', subtitle: 'Status and what is needed', href: at('/verify') },
    ],
  };
}

// The business section follows the business chosen in the switcher. A person with no business sees an invitation to add
// one, never the management tools.
export function businessSection(f: HubFacts): HubSection | null {
  if (f.context === 'personal') return null;
  const b = f.businesses.find((x) => x.id === f.context);
  if (!b) return null;
  const id = { id: b.id };
  const items: HubItem[] = [
    { key: 'storefront', title: 'Business profile', subtitle: 'Your business page and details', href: at('/business/manage/[id]', id) },
    { key: 'public', title: 'View public storefront', subtitle: 'How buyers see it', href: at('/business/[slug]', { slug: b.slug }) },
  ];
  if (roleCan(b.role, 'manage_catalogues')) items.push({ key: 'catalogue', title: 'Product catalogue', subtitle: 'Groups of products in your storefront', href: at('/business/manage/[id]/catalogues', id) });
  if (roleCan(b.role, 'manage_inventory')) items.push({ key: 'inventory', title: 'Inventory', subtitle: 'Stock levels and history', href: at('/business/manage/[id]/inventory', id) });
  if (roleCan(b.role, 'manage_orders')) items.push({ key: 'biz-orders', title: 'Business orders', subtitle: 'Orders for this business', href: at('/business/manage/[id]/orders', id) });
  if (roleCan(b.role, 'manage_branches')) items.push({ key: 'branches', title: 'Branches', subtitle: 'Your shops and pickup points', href: at('/business/manage/[id]/branches', id) });
  if (roleCan(b.role, 'view_team')) items.push({ key: 'team', title: 'Staff and permissions', subtitle: 'Who can do what', href: at('/business/manage/[id]/team', id) });
  if (roleCan(b.role, 'view_analytics')) items.push({ key: 'biz-analytics', title: 'Business analytics', subtitle: 'Sales and product performance', href: at('/analytics', { business: b.id }) });
  if (b.role === 'owner' && !b.verified) items.push({ key: 'biz-verify', title: 'Verify this business', subtitle: 'Needed for a verified badge', href: at('/verify/business') });
  return { key: 'business', title: `Business centre: ${b.name}`, items };
}

// Selling is opt-in. A buyer sees an invitation, not the tools. Business registration is separate from selling as a person.
export function becomeSellerSection(f: HubFacts): HubSection | null {
  const items: HubItem[] = [];
  if (!f.isSeller) {
    items.push({ key: 'become-seller', title: 'Become an individual seller', subtitle: 'For people selling their own products. Verify your identity to start.', href: at('/verify'), badge: 'Application required' });
  }
  if (f.businesses.length === 0) {
    items.push({ key: 'register-business', title: 'Register a business', subtitle: 'For shops, companies and organisations', href: at('/business/manage'), badge: 'Verification required' });
  }
  if (items.length === 0) return null;
  return { key: 'become-seller', title: 'Become a seller', items };
}

export function communicationSection(f: HubFacts): HubSection {
  return {
    key: 'communication',
    title: 'Communication and support',
    items: [
      { key: 'notifications', title: 'Notifications', subtitle: 'Updates about your orders and account', href: at('/notifications'), badge: count(f.unreadNotifications, 'new') },
      { key: 'messages', title: 'Messages', subtitle: 'Chats with buyers and sellers', href: at('/(tabs)/messages') },
      { key: 'support', title: 'Help and support', subtitle: 'Ask for help and follow your requests', href: at('/support') },
      { key: 'cases', title: 'Disputes, appeals and reports', subtitle: 'Where each of your cases stands', href: at('/account/cases') },
    ],
  };
}

export function settingsSection(): HubSection {
  return {
    key: 'settings',
    title: 'Account settings',
    items: [
      { key: 'personal', title: 'Personal information', subtitle: 'Name and about you', href: at('/profile/edit') },
      { key: 'addresses', title: 'Saved addresses', subtitle: 'Delivery and pickup places', href: at('/addresses') },
      { key: 'security', title: 'Security and login', subtitle: 'Password, email and other devices', href: at('/settings/security') },
      { key: 'notification-settings', title: 'Notification preferences', subtitle: 'Choose what you are told about', href: at('/notification-settings') },
    ],
  };
}

export function staffSection(f: HubFacts): HubSection | null {
  if (!f.isStaff) return null;
  return { key: 'staff', title: 'Staff', items: [{ key: 'staff-tools', title: 'Staff tools', subtitle: 'Only people with a staff role see this', href: at('/admin') }] };
}

export function buildHub(f: HubFacts): HubSection[] {
  return [
    purchasesSection(f),
    f.isSeller ? sellingSection(f) : null,
    businessSection(f),
    becomeSellerSection(f),
    communicationSection(f),
    settingsSection(),
    staffSection(f),
  ].filter(
    (s): s is HubSection => s !== null,
  );
}

// The switcher offers "personal" always, plus one entry per business the person belongs to.
export function contextOptions(businesses: HubBusiness[]): { key: string; label: string }[] {
  return [{ key: 'personal', label: 'Personal' }, ...businesses.map((b) => ({ key: b.id, label: b.name }))];
}

export function validContext(context: string, businesses: HubBusiness[]): string {
  return context === 'personal' || businesses.some((b) => b.id === context) ? context : 'personal';
}

export function memberSince(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'Africa/Lusaka' });
}

export function emailStatus(confirmedAt: string | null | undefined): 'verified' | 'unverified' {
  return confirmedAt ? 'verified' : 'unverified';
}

export function profileProblem(name: string, bio: string): string | null {
  const n = name.trim();
  if (n.length < 2 || n.length > 60) return 'Your name must be between 2 and 60 characters.';
  if (bio.trim().length > 500) return 'About you must be 500 characters or fewer.';
  return null;
}

export function passwordProblem(next: string, again: string): string | null {
  if (next.length < 8) return 'Use at least 8 characters.';
  if (next !== again) return 'The two passwords do not match.';
  return null;
}
