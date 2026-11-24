import {
  canHandleReports, canManageTeam, canModerate, canReadTrust, canSeeFinance, canSeeTrustAudit, canSupport, canWorkTickets,
  type AdminRole,
} from './admin';

// The web admin console's menu. Which items show is decided here from the staff member's roles, but the database
// is what actually allows or refuses every action; hiding an item is only a convenience.
export type ConsoleItem = { key: string; title: string; group: string; href: string; allowed: (roles: AdminRole[]) => boolean };

const anyStaff = (roles: AdminRole[]) => roles.length > 0;

export const CONSOLE_ITEMS: ConsoleItem[] = [
  { key: 'listings', title: 'Listings to review', group: 'Moderation', href: '/console/listings', allowed: canModerate },
  { key: 'appeals', title: 'Appeals', group: 'Moderation', href: '/console/appeals', allowed: canModerate },
  { key: 'flags', title: 'Risk flags', group: 'Moderation', href: '/console/flags', allowed: canModerate },
  { key: 'reports', title: 'Reports', group: 'Moderation', href: '/console/reports', allowed: canHandleReports },
  { key: 'users', title: 'Users and trust', group: 'People', href: '/console/trust', allowed: canSeeTrustAudit },
  { key: 'verifications', title: 'Verification requests', group: 'People', href: '/console/verifications', allowed: canSupport },
  { key: 'disputes', title: 'Disputes', group: 'People', href: '/console/disputes', allowed: canSupport },
  { key: 'helpdesk', title: 'Help desk', group: 'People', href: '/console/helpdesk', allowed: canWorkTickets },
  { key: 'finance', title: 'Payments and refunds', group: 'Money', href: '/console/finance', allowed: canSeeFinance },
  { key: 'stats', title: 'Platform statistics', group: 'Platform', href: '/console/stats', allowed: (r) => canSeeFinance(r) || canReadTrust(r) || canManageTeam(r) },
  { key: 'team', title: 'Staff team', group: 'Platform', href: '/console/team', allowed: canManageTeam },
  { key: 'audit', title: 'Audit log', group: 'Platform', href: '/console/audit', allowed: canManageTeam },
  { key: 'votes', title: 'Staff voting', group: 'Staff', href: '/console/votes', allowed: anyStaff },
  { key: 'birthdays', title: 'Staff birthdays', group: 'Staff', href: '/console/birthdays', allowed: anyStaff },
];

export const CONSOLE_HOME = '/console';

const GROUP_ORDER = ['Moderation', 'People', 'Money', 'Platform', 'Staff'];

export type ConsoleGroup = { group: string; items: ConsoleItem[] };

export function consoleMenu(roles: AdminRole[]): ConsoleGroup[] {
  const visible = CONSOLE_ITEMS.filter((i) => i.allowed(roles));
  return GROUP_ORDER.map((group) => ({ group, items: visible.filter((i) => i.group === group) })).filter((g) => g.items.length > 0);
}

// Which menu item a path belongs to, so the sidebar can highlight it. "/console/votes/new" belongs to "votes".
export function activeItemKey(pathname: string): string | null {
  const hit = CONSOLE_ITEMS.find((i) => pathname === i.href || pathname.startsWith(`${i.href}/`));
  return hit?.key ?? null;
}

// Wide screens get a side menu; narrow ones get a menu button.
export const WIDE_BREAKPOINT = 900;
export const isWide = (width: number) => width >= WIDE_BREAKPOINT;
