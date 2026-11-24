// Staff birthdays. The database decides who may see what and when notices go out (migration 0017).
// This file only works out what to show. Only a day and a month are ever stored: there is no year anywhere.

export const MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
] as const;

export type Visibility = 'staff' | 'hidden';

export const VISIBILITY_LABELS: Record<Visibility, { label: string; hint: string }> = {
  staff: { label: 'Visible to staff', hint: 'Colleagues see your birthday in the calendar and are told on the day.' },
  hidden: { label: 'Only me', hint: 'Nobody else sees it or is told. You still get a greeting.' },
};

// 29 February is allowed. In years that are not leap years it is celebrated on 28 February.
export function daysInMonth(month: number): number {
  if (month === 2) return 29;
  if ([4, 6, 9, 11].includes(month)) return 30;
  return 31;
}

export function birthdayProblem(month: number | null, day: number | null): string | null {
  if (month === null || !Number.isInteger(month) || month < 1 || month > 12) return 'Choose a month.';
  if (day === null || !Number.isInteger(day) || day < 1) return 'Enter the day of the month.';
  if (day > daysInMonth(month)) return `${MONTHS[month - 1]} does not have ${day} days.`;
  return null;
}

// "5 March". Never a year.
export function formatBirthday(month: number, day: number): string {
  if (month < 1 || month > 12) return '';
  return `${day} ${MONTHS[month - 1]}`;
}

export function daysUntilLabel(days: number): string {
  if (days <= 0) return 'Today';
  if (days === 1) return 'Tomorrow';
  return `In ${days} days`;
}

export const MAX_WISH = 500;

export function wishProblem(text: string): string | null {
  const t = text.trim();
  if (t.length === 0) return 'Write a wish first.';
  if (t.length > MAX_WISH) return `Keep it under ${MAX_WISH} characters.`;
  return null;
}

export function wishesLeft(written: number, max: number): number {
  return Math.max(0, max - written);
}

export function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '?';
  const first = parts[0]?.[0] ?? '';
  const last = parts.length > 1 ? (parts[parts.length - 1]?.[0] ?? '') : '';
  return (first + last).toUpperCase();
}

// The status line on a board, so the person knows why they cannot write.
export function boardNote(opts: { isMe: boolean; canWrite: boolean; written: number; max: number }): string {
  if (opts.isMe) return 'This is your board. Colleagues can leave you wishes here.';
  if (opts.canWrite) return `You can leave ${wishesLeft(opts.written, opts.max)} more wish${wishesLeft(opts.written, opts.max) === 1 ? '' : 'es'}.`;
  if (opts.written >= opts.max) return 'You have left the most wishes allowed here.';
  return 'Wishes are closed for this birthday.';
}
