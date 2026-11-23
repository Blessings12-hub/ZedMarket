export type NotificationCategory = 'orders' | 'messages' | 'alerts' | 'listings' | 'business' | 'account';

export const CATEGORIES: { key: NotificationCategory; label: string; hint: string }[] = [
  { key: 'orders', label: 'Orders', hint: 'Requests, confirmations, deliveries and disputes' },
  { key: 'messages', label: 'Messages', hint: 'New chat messages' },
  { key: 'alerts', label: 'Saved search alerts', hint: 'New listings that match what you saved' },
  { key: 'listings', label: 'Your listings', hint: 'Review results and low stock' },
  { key: 'business', label: 'Business', hint: 'Team invitations and shop updates' },
  { key: 'account', label: 'Account and safety', hint: 'Verification and account changes. Always on.' },
];

export function categoryLabel(key: string): string {
  return CATEGORIES.find((c) => c.key === key)?.label ?? 'Other';
}

// Account notices cannot be switched off in the app or on the server.
export function canTurnOff(category: string): boolean {
  return category !== 'account';
}

// Only paths made of plain characters, and only screens the app really has, are opened from a
// notification. Anything else (a link from an old version, a bad value) falls back to the inbox.
const ALLOWED_TOP = new Set(['order', 'listing', 'chat', 'dispute', 'seller', 'business', 'account', 'orders', 'alerts', 'appeal', 'verify']);

export function routeForNotification(link: string | null | undefined): string | null {
  if (!link) return null;
  if (!/^\/[A-Za-z0-9/_.-]*$/.test(link) || link.includes('..') || link.includes('//')) return null;
  const top = link.split('/')[1];
  if (!top) return null;
  if (top === 'account') return '/(tabs)/account';
  return ALLOWED_TOP.has(top) ? link : null;
}

export function unreadLabel(count: number): string {
  if (count <= 0) return '';
  return count > 99 ? '99+' : String(count);
}

export function relativeTime(iso: string, now: Date = new Date()): string {
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return '';
  const mins = Math.floor((now.getTime() - t) / 60000);
  if (mins < 1) return 'Just now';
  if (mins < 60) return `${mins} min ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days} d ago`;
  return new Date(t).toISOString().slice(0, 10);
}
