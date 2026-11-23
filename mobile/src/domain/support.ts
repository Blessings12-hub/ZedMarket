export type TicketStatus = 'open' | 'in_progress' | 'waiting_on_customer' | 'escalated' | 'resolved' | 'closed';

// What the customer is told. "Escalated" is shown as a review by a second person, never as a problem.
export function customerStatusLabel(s: string): string {
  switch (s) {
    case 'open': return 'Received';
    case 'in_progress': return 'Being looked at';
    case 'waiting_on_customer': return 'Waiting for your reply';
    case 'escalated': return 'With a senior team member';
    case 'resolved': return 'Resolved';
    case 'closed': return 'Closed';
    default: return s;
  }
}

export function staffStatusLabel(s: string): string {
  switch (s) {
    case 'open': return 'Open';
    case 'in_progress': return 'In progress';
    case 'waiting_on_customer': return 'Waiting on customer';
    case 'escalated': return 'Escalated';
    case 'resolved': return 'Resolved';
    case 'closed': return 'Closed';
    default: return s;
  }
}

export const RESOLUTION_CODES: { key: string; label: string }[] = [
  { key: 'fixed', label: 'Fixed' },
  { key: 'explained', label: 'Explained' },
  { key: 'refunded', label: 'Refunded' },
  { key: 'duplicate', label: 'Duplicate' },
  { key: 'no_action', label: 'No action needed' },
  { key: 'not_resolvable', label: 'Could not be resolved' },
];

export function resolutionLabel(code: string | null): string {
  if (code === 'customer_withdrew') return 'Closed by you';
  return RESOLUTION_CODES.find((r) => r.key === code)?.label ?? '';
}

export function ticketFormProblem(subject: string, description: string): string | null {
  if (subject.trim().length < 5) return 'Give the problem a short title (at least 5 letters).';
  if (description.trim().length < 10) return 'Say a little more (at least one sentence).';
  return null;
}

export function customerCanReply(status: string): boolean {
  return status !== 'closed';
}

export function customerCanRate(status: string, code: string | null, rating: number | null): boolean {
  return (status === 'resolved' || status === 'closed') && code !== 'customer_withdrew' && rating === null;
}

export const MAX_ATTACHMENTS = 5;

// A late ticket is one with no first reply after its target time.
export function isOverdue(dueAt: string, firstResponded: boolean, status: string, now: Date = new Date()): boolean {
  if (firstResponded) return false;
  if (!['open', 'in_progress', 'escalated'].includes(status)) return false;
  return new Date(dueAt).getTime() < now.getTime();
}

export function metricLabel(metric: string): string {
  const names: Record<string, string> = {
    created: 'Tickets opened', resolved: 'Tickets resolved', open_now: 'Open now', waiting_on_customer_now: 'Waiting on customers',
    escalated_now: 'Escalated now', unassigned_now: 'Nobody has taken yet', overdue_now: 'Late for a first reply',
    avg_first_response_minutes: 'Average first reply (minutes)', avg_resolution_hours: 'Average time to resolve (hours)',
    avg_rating: 'Average rating (out of 5)', rated: 'Tickets rated',
  };
  return names[metric] ?? metric;
}
