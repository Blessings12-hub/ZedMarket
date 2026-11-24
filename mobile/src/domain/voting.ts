// Staff voting. The database counts the votes and decides every result (migration 0015).
// Nothing here can change an outcome; it only works out what to show.

export type ProposalStatus = 'draft' | 'pending' | 'active' | 'approved' | 'rejected' | 'unresolved' | 'cancelled';
export type VoteChoice = 'for' | 'against' | 'abstain';
export type VoteSection = 'active' | 'upcoming' | 'completed' | 'unresolved' | 'mine';

// Same formula as the database: ceiling(eligible * 2 / 3), written with whole numbers only.
export function requiredVotes(eligible: number): number {
  if (!Number.isInteger(eligible) || eligible < 1) return 0;
  return Math.floor((eligible * 2 + 2) / 3);
}

export const SECTIONS: { key: VoteSection; label: string; empty: string }[] = [
  { key: 'active', label: 'Active votes', empty: 'No votes are open right now.' },
  { key: 'upcoming', label: 'Upcoming votes', empty: 'No votes are scheduled.' },
  { key: 'completed', label: 'Completed votes', empty: 'No votes have been decided yet.' },
  { key: 'unresolved', label: 'Unresolved votes', empty: 'No votes have ended without a result.' },
  { key: 'mine', label: 'My proposals', empty: 'You have not made any proposals.' },
];

export const STATUS_LABELS: Record<ProposalStatus, string> = {
  draft: 'Draft',
  pending: 'Scheduled',
  active: 'Open for voting',
  approved: 'Approved',
  rejected: 'Rejected',
  unresolved: 'Unresolved',
  cancelled: 'Cancelled',
};

export const CHOICE_LABELS: Record<VoteChoice, string> = { for: 'For', against: 'Against', abstain: 'Abstain' };

export function statusLabel(status: string): string {
  return STATUS_LABELS[status as ProposalStatus] ?? status;
}

export function choiceLabel(choice: string | null | undefined): string {
  if (!choice) return 'Not voted';
  return CHOICE_LABELS[choice as VoteChoice] ?? choice;
}

export function isFinal(status: string): boolean {
  return status === 'approved' || status === 'rejected' || status === 'unresolved' || status === 'cancelled';
}

export function isDecided(status: string): boolean {
  return status === 'approved' || status === 'rejected' || status === 'unresolved';
}

// Plain-language line explaining what the result means, so nobody reads it as a simple-majority rule.
export function outcomeExplanation(status: string, required: number | null, eligible: number | null): string {
  const rule = required && eligible ? `${required} of ${eligible}` : 'two thirds';
  switch (status) {
    case 'approved':
      return `Approved: at least ${rule} eligible staff voted for it.`;
    case 'rejected':
      return `Rejected: at least ${rule} eligible staff voted against it.`;
    case 'unresolved':
      return `Unresolved: neither side reached ${rule} eligible staff. A simple majority is not enough.`;
    case 'cancelled':
      return 'Cancelled. No result was recorded.';
    default:
      return '';
  }
}

export type Tally = { for: number | null; against: number | null; abstain: number | null; hidden: boolean };

// How many more votes each side would still need.
export function stillNeeded(tally: Tally, required: number | null): { forNeeds: number; againstNeeds: number } | null {
  if (tally.hidden || required === null || tally.for === null || tally.against === null) return null;
  return { forNeeds: Math.max(0, required - tally.for), againstNeeds: Math.max(0, required - tally.against) };
}

export function countsLine(tally: Tally): string {
  if (tally.hidden) return 'Counts are hidden until this vote closes.';
  return `For ${tally.for ?? 0} · Against ${tally.against ?? 0} · Abstain ${tally.abstain ?? 0}`;
}

export function timeLeft(closesAt: string | null, now: Date = new Date()): string {
  if (!closesAt) return '';
  const ms = new Date(closesAt).getTime() - now.getTime();
  if (Number.isNaN(ms)) return '';
  if (ms <= 0) return 'Closing now';
  const mins = Math.floor(ms / 60000);
  if (mins < 60) return `${Math.max(mins, 1)} min left`;
  const hours = Math.floor(mins / 60);
  if (hours < 48) return `${hours} h left`;
  return `${Math.floor(hours / 24)} days left`;
}

export function formatWhen(iso: string | null, timeZone = 'Africa/Lusaka'): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleString('en-GB', { timeZone, day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

export const MIN_TITLE = 5;
export const MIN_BODY = 10;

export type ProposalForm = { title: string; description: string; reason: string; confirmedNoOverride: boolean };

// Checks the form before it is sent. The database checks again.
export function proposalProblem(form: ProposalForm): string | null {
  const title = form.title.trim();
  if (title.length < MIN_TITLE) return `The title needs at least ${MIN_TITLE} characters.`;
  if (title.length > 120) return 'Keep the title under 120 characters.';
  if (form.description.trim().length < MIN_BODY) return 'Describe what is being decided (at least 10 characters).';
  if (form.description.trim().length > 4000) return 'Keep the description under 4000 characters.';
  if (form.reason.trim().length < MIN_BODY) return 'Say why this is needed (at least 10 characters).';
  if (form.reason.trim().length > 2000) return 'Keep the reason under 2000 characters.';
  if (!form.confirmedNoOverride) return 'Confirm that this does not ask staff to override legal, security or emergency duties.';
  return null;
}

// Voting period in hours, as chosen on the proposal form. Bounds mirror the database starter settings.
export const PERIOD_CHOICES: { hours: number; label: string }[] = [
  { hours: 24, label: '1 day' },
  { hours: 72, label: '3 days' },
  { hours: 168, label: '7 days' },
  { hours: 336, label: '14 days' },
];

export function closesAtFor(hours: number, now: Date = new Date()): string {
  return new Date(now.getTime() + hours * 3600_000).toISOString();
}
