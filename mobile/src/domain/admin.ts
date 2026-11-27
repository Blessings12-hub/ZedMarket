export type AdminRole = 'support' | 'moderator' | 'finance' | 'tech_admin' | 'media';

export type StaffStep = 'not_staff' | 'enrol' | 'verify' | 'ready';

// Staff actions in the database need a second sign-in step (two-factor).
// This decides which screen a staff member should see next.
export function staffAccessStep(
  roles: AdminRole[],
  currentLevel: string | null | undefined,
  nextLevel: string | null | undefined,
): StaffStep {
  if (roles.length === 0) return 'not_staff';
  if (currentLevel === 'aal2') return 'ready';
  if (nextLevel === 'aal2') return 'verify';
  return 'enrol';
}

// These mirror the checks inside the database functions. The database is what
// actually enforces them; this only decides which buttons to show.
export function canModerate(roles: AdminRole[]): boolean {
  return roles.includes('moderator');
}

export function canHandleReports(roles: AdminRole[]): boolean {
  return roles.includes('moderator') || roles.includes('support');
}

export function canSupport(roles: AdminRole[]): boolean {
  return roles.includes('support');
}

export function canManageTeam(roles: AdminRole[]): boolean {
  return roles.includes('tech_admin');
}

export const ROLE_LABELS: Record<AdminRole, string> = {
  support: 'Support',
  moderator: 'Moderator',
  finance: 'Finance',
  tech_admin: 'Technical admin',
  media: 'Media',
};

export const MIN_REASON_LENGTH = 3;

export function reasonProblem(reason: string): string | null {
  const text = reason.trim();
  if (text.length < MIN_REASON_LENGTH) return 'Write a short reason. It is saved in the audit log.';
  if (text.length > 500) return 'Keep the reason under 500 characters.';
  return null;
}

export function cleanTotpCode(input: string): string {
  return input.replace(/\D/g, '').slice(0, 6);
}

// User & Trust Management. Again, the database decides; these only choose what to show.
export function canReadTrust(roles: AdminRole[]): boolean {
  return roles.includes('support') || roles.includes('moderator');
}

export function canReviewApplications(roles: AdminRole[]): boolean {
  return roles.includes('support');
}

export function canChangeAccountState(roles: AdminRole[]): boolean {
  return roles.includes('moderator');
}

export function canSeeTrustAudit(roles: AdminRole[]): boolean {
  return canReadTrust(roles) || roles.includes('tech_admin');
}

export function canSeeFinance(roles: AdminRole[]): boolean {
  return roles.includes('finance');
}

export function canWorkTickets(roles: AdminRole[]): boolean {
  return roles.includes('support') || roles.includes('tech_admin');
}

// What each staff role is responsible for. Every item marked "enforced" is checked by the database itself
// (has_staff_role plus a two-factor session); this list only explains it on screen. Items under "coming" are not
// built yet and are shown separately so nobody assumes they exist.
export type RoleJobs = { summary: string; enforced: string[]; coming: string[] };

export const ROLE_JOBS: Record<AdminRole, RoleJobs> = {
  finance: {
    summary: 'Money in and out of the platform: payments, refunds and the numbers that prove them.',
    enforced: [
      'Reconcile a payment by hand when the provider never answered or answered late. You must write what you checked.',
      'Request a refund against a settled payment, within the amount still refundable.',
      'Decide a refund that someone else requested. You can never approve your own request, and a rejection needs a reason.',
      'Record that an approved refund was paid out (or failed), with the provider reference.',
      'Read the payments list, payment details, the refund queue and the finance summary.',
      'Read finance and platform statistics.',
    ],
    coming: [
      'Reconcile advertising payments (arrives with the advertising module).',
      'Refund an unused advertising balance (arrives with the advertising module).',
    ],
  },
  moderator: {
    summary: 'Keeping listings and reports within the rules.',
    enforced: ['Approve, reject or remove listings.', 'Handle reports and risk flags.', 'Review appeals and verification requests.'],
    coming: ['Work the product moderation queue, highest risk first.'],
  },
  support: {
    summary: 'Helping people with their orders, accounts and disputes.',
    enforced: ['Work help desk tickets.', 'Handle reports and disputes.', 'Read the user trust view.'],
    coming: [],
  },
  tech_admin: {
    summary: 'Who has staff access, and the health of the platform.',
    enforced: ['Add and remove staff roles.', 'Read the audit log.', 'Read platform statistics.', 'Appoint people to the Media department and give or take away individual Media permissions.', 'Review, approve and publish Media content.'],
    coming: [],
  },
  media: {
    summary: 'ZedMarket\'s visual identity, announcements and campaigns.',
    enforced: [
      'Upload and organise images, videos and graphics in the Media Library.',
      'Create content and submit it for approval. You cannot approve your own work.',
      'Plan campaigns and the content calendar, and answer requests from other departments.',
      'Publish only if an administrator has given you publishing authority.',
    ],
    coming: [],
  },
};

export function jobsFor(roles: AdminRole[]): { role: AdminRole; jobs: RoleJobs }[] {
  const order: AdminRole[] = ['finance', 'moderator', 'support', 'tech_admin', 'media'];
  return order.filter((r) => roles.includes(r)).map((role) => ({ role, jobs: ROLE_JOBS[role] }));
}
