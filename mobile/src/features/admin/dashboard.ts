// The "needs attention" board at the top of Staff tools. It only decides what to show and in what order:
// the database still checks every action, so hiding a card is a convenience, never a lock.
import { canHandleReports, canModerate, canReviewApplications, canSupport, type AdminRole } from '../../domain/admin';

export type QueueKey = 'applications' | 'listings' | 'reports' | 'disputes' | 'appeals' | 'flags' | 'verifications';
export type QueueFact = { count: number; oldest: string | null; overdue?: number };
export type StaffCounts = Partial<Record<QueueKey, QueueFact>>;

type QueueDef = { key: QueueKey; title: string; href: string; allowed: (roles: AdminRole[]) => boolean; urgentAfterHours: number };

// The oldest item matters more than the size of the queue: a seller waiting a week is worse than ten waiting an hour.
const QUEUES: QueueDef[] = [
  { key: 'applications', title: 'Seller applications', href: '/trust/seller-applications', allowed: canReviewApplications, urgentAfterHours: 48 },
  { key: 'disputes', title: 'Disputes', href: '/admin/disputes', allowed: canSupport, urgentAfterHours: 72 },
  { key: 'verifications', title: 'Verification requests', href: '/admin/verifications', allowed: canSupport, urgentAfterHours: 72 },
  { key: 'reports', title: 'Reports', href: '/admin/reports', allowed: canHandleReports, urgentAfterHours: 48 },
  { key: 'listings', title: 'Listings to review', href: '/admin/listings', allowed: canModerate, urgentAfterHours: 24 },
  { key: 'appeals', title: 'Appeals', href: '/admin/appeals', allowed: canModerate, urgentAfterHours: 72 },
  { key: 'flags', title: 'Risk flags', href: '/admin/flags', allowed: canModerate, urgentAfterHours: 72 },
];

export const QUEUE_KEYS = QUEUES.map((q) => q.key);

const HOUR = 3_600_000;

// "waiting 3 days", "waiting 5 hours", "just arrived". Bad or future dates say nothing rather than something wrong.
export function waitingLabel(iso: string | null, now: number): string | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (!Number.isFinite(t) || t > now) return null;
  const hours = Math.floor((now - t) / HOUR);
  if (hours < 1) return 'just arrived';
  if (hours < 48) return `waiting ${hours} hour${hours === 1 ? '' : 's'}`;
  const days = Math.floor(hours / 24);
  return `waiting ${days} days`;
}

export type StaffCard = { key: QueueKey; title: string; href: string; count: number; waiting: string | null; urgent: boolean };
// hasQueues is false for roles with no queue to work (finance, tech admin): they get no board instead of a false "all clear".
export type StaffBoard = { cards: StaffCard[]; total: number; allClear: boolean; hasQueues: boolean };

// Only queues this person's roles allow, only those with something in them, most urgent first, then oldest first.
export function staffBoard(roles: AdminRole[], counts: StaffCounts, now: number): StaffBoard {
  const cards = QUEUES.filter((q) => q.allowed(roles)).flatMap((q): (StaffCard & { age: number })[] => {
    const fact = counts[q.key];
    const count = fact && Number.isFinite(fact.count) ? Math.max(0, Math.floor(fact.count)) : 0;
    if (count === 0) return [];
    const t = fact?.oldest ? Date.parse(fact.oldest) : NaN;
    const age = Number.isFinite(t) && t <= now ? now - t : 0;
    const urgent = (fact?.overdue ?? 0) > 0 || age > q.urgentAfterHours * HOUR;
    return [{ key: q.key, title: q.title, href: q.href, count, waiting: waitingLabel(fact?.oldest ?? null, now), urgent, age }];
  });
  cards.sort((a, b) => Number(b.urgent) - Number(a.urgent) || b.age - a.age || b.count - a.count);
  return {
    cards: cards.map(({ age: _age, ...c }) => c),
    total: cards.reduce((n, c) => n + c.count, 0),
    allClear: cards.length === 0,
    hasQueues: QUEUES.some((q) => q.allowed(roles)),
  };
}
