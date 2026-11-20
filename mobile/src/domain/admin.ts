export type AdminRole = 'support' | 'moderator' | 'finance' | 'tech_admin';

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
