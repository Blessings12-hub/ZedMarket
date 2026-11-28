import {
  canHandleReports, canManageTeam, canModerate, canReadTrust, canSeeFinance, canSeeTrustAudit, canSupport, canWorkTickets,
  type AdminRole,
} from './admin';

// The Staff tools home. Which rows show is decided here from the person's roles, but the database is what actually
// allows or refuses every action; hiding a row is only a convenience.
export type StaffMenuItem = { key: string; title: string; note: string; href: string; allowed: (roles: AdminRole[], perms: readonly string[]) => boolean };
export type StaffMenuSection = { title: string; items: StaffMenuItem[] };

const anyStaff = (roles: AdminRole[]) => roles.length > 0;

const SECTIONS: { title: string; items: StaffMenuItem[] }[] = [
  {
    title: 'Moderation',
    items: [
      { key: 'listings', title: 'Listings to review', note: 'Approve or reject products waiting for a check', href: '/admin/listings', allowed: canModerate },
      { key: 'appeals', title: 'Appeals', note: 'Decisions people have asked us to look at again', href: '/admin/appeals', allowed: canModerate },
      { key: 'promotions', title: 'Promotion requests', note: 'Paid promotions waiting for approval', href: '/admin/promotions', allowed: canModerate },
      { key: 'flags', title: 'Risk flags', note: 'Accounts and listings the system has marked', href: '/admin/flags', allowed: canModerate },
      { key: 'reports', title: 'Reports', note: 'Reports from buyers and sellers', href: '/admin/reports', allowed: canHandleReports },
    ],
  },
  {
    title: 'People and support',
    items: [
      { key: 'users', title: 'Users and trust', note: 'Find a person, see their history, change account state', href: '/trust', allowed: canSeeTrustAudit },
      { key: 'verifications', title: 'Verification requests', note: 'Identity and business checks', href: '/admin/verifications', allowed: canSupport },
      { key: 'disputes', title: 'Disputes', note: 'Orders where buyer and seller disagree', href: '/admin/disputes', allowed: canSupport },
      { key: 'helpdesk', title: 'Help desk', note: 'Customer tickets and replies', href: '/helpdesk', allowed: canWorkTickets },
    ],
  },
  {
    title: 'Finance',
    items: [
      { key: 'finance', title: 'Payments and refunds', note: 'Reconcile payments, request and decide refunds', href: '/finance', allowed: canSeeFinance },
    ],
  },
  {
    title: 'Platform',
    items: [
      { key: 'health', title: 'App health', note: 'Crashes, late tickets and stuck queues in one place', href: '/admin/health', allowed: canManageTeam },
      { key: 'stats', title: 'Statistics', note: 'Platform numbers', href: '/admin/stats', allowed: (r) => canSeeFinance(r) || canReadTrust(r) || canManageTeam(r) },
      { key: 'team', title: 'Staff team', note: 'Who has which staff role', href: '/admin/team', allowed: canManageTeam },
      { key: 'access', title: 'Pause or restore access', note: 'Switch a department off or on for one person', href: '/admin/access', allowed: canManageTeam },
      { key: 'audit', title: 'Audit log', note: 'A permanent record of staff actions', href: '/admin/audit', allowed: canManageTeam },
    ],
  },
  {
    title: 'Media',
    items: [
      { key: 'media', title: 'Media Department', note: 'Content, library, campaigns and announcements', href: '/media', allowed: (_r, p) => p.includes('media.access') },
      { key: 'media_people', title: 'Media staff', note: 'Appoint, remove and set permissions for Media staff', href: '/media/people', allowed: (r) => canManageTeam(r) },
      { key: 'media_ask', title: 'Ask Media for something', note: 'Request a poster, announcement or campaign', href: '/media/requests', allowed: (r, p) => anyStaff(r) && !p.includes('media.requests') },
    ],
  },
  {
    title: 'Our team',
    items: [
      { key: 'jobs', title: 'Your jobs', note: 'What your role is responsible for', href: '/admin/jobs', allowed: anyStaff },
      { key: 'votes', title: 'Votes and proposals', note: 'Staff decisions that need a two-thirds vote', href: '/admin/votes', allowed: anyStaff },
      { key: 'birthdays', title: 'Birthdays and wishes', note: 'Calendar and messages for colleagues', href: '/admin/birthdays', allowed: anyStaff },
    ],
  },
];

// Media rows depend on permissions (not only roles), so the permission list is passed in when it is known.
export function staffMenu(roles: AdminRole[], perms: readonly string[] = []): StaffMenuSection[] {
  return SECTIONS.map((s) => ({ title: s.title, items: s.items.filter((i) => i.allowed(roles, perms)) })).filter((s) => s.items.length > 0);
}

export const STAFF_MENU_KEYS = SECTIONS.flatMap((s) => s.items.map((i) => i.key));
