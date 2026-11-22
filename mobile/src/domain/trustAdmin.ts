export type ApplicationKind = 'identity' | 'business';
export type ApplicationStatus = 'pending' | 'approved' | 'rejected';
export type UserFilter = 'all' | 'verified' | 'suspended' | 'restricted';

export const STATUS_LABELS: Record<ApplicationStatus, string> = {
  pending: 'Pending',
  approved: 'Verified',
  rejected: 'Rejected',
};

export const USER_FILTER_LABELS: Record<UserFilter, string> = {
  all: 'Everyone',
  verified: 'Verified',
  suspended: 'Suspended',
  restricted: 'Restricted',
};

export function auditActionLabel(action: string): string {
  switch (action) {
    case 'identity.reviewed':
      return 'Identity application decided';
    case 'business.reviewed':
      return 'Business application decided';
    case 'account.state_changed':
      return 'Account state changed';
    case 'document.viewed':
      return 'Document opened';
    default:
      return action.replace(/[._]/g, ' ');
  }
}

// One plain sentence about what the entry's details say. Never throws on odd data.
export function auditDetail(action: string, metadata: Record<string, unknown> | null | undefined): string {
  const m = metadata ?? {};
  const note = typeof m.note === 'string' && m.note ? ` Note: ${m.note}` : '';
  switch (action) {
    case 'identity.reviewed':
    case 'business.reviewed':
      return `${m.approved ? 'Approved.' : 'Rejected.'}${note}`;
    case 'account.state_changed': {
      const reason = typeof m.reason === 'string' ? ` Reason: ${m.reason}` : '';
      return `Set to ${String(m.state ?? 'unknown')}.${reason}`;
    }
    case 'document.viewed':
      return `${m.kind === 'business' ? 'Business' : 'Identity'} document.`;
    default:
      return '';
  }
}

// Staff may only pick a state different from the current one.
export function nextAccountStates(current: 'active' | 'restricted' | 'suspended'): Array<'active' | 'restricted' | 'suspended'> {
  return (['active', 'restricted', 'suspended'] as const).filter((s) => s !== current);
}

export function stateActionLabel(state: 'active' | 'restricted' | 'suspended'): string {
  return state === 'active' ? 'Reinstate' : state === 'restricted' ? 'Restrict' : 'Suspend';
}
