// Display and export helpers for the analytics screens. The numbers themselves are worked out in the database.

export const PERIODS = [7, 30, 90] as const;

export function percentText(value: number | null | undefined): string {
  if (value === null || value === undefined || Number.isNaN(value)) return 'No data yet';
  return `${Number.isInteger(value) ? value : value.toFixed(1)}%`;
}

export function hoursText(hours: number | null | undefined): string {
  if (hours === null || hours === undefined || Number.isNaN(hours)) return 'No data yet';
  if (hours < 1) return `${Math.round(hours * 60)} min`;
  if (hours < 48) return `${Number.isInteger(hours) ? hours : hours.toFixed(1)} hours`;
  const days = hours / 24;
  return `${Number.isInteger(days) ? days : days.toFixed(1)} days`;
}

export function minutesText(minutes: number | null | undefined): string {
  if (minutes === null || minutes === undefined || Number.isNaN(minutes)) return 'No data yet';
  return minutes < 60 ? `${Math.round(minutes)} min` : hoursText(minutes / 60);
}

export function ratingText(value: number | null | undefined, count: number): string {
  if (!count || value === null || value === undefined) return 'No reviews yet';
  return `${value.toFixed(1)} out of 5 (${count} review${count === 1 ? '' : 's'})`;
}

// The database sends numbers inside JSON, sometimes as text (numeric columns). This turns either into a number.
export function num(value: unknown): number {
  if (typeof value === 'number') return Number.isFinite(value) ? value : 0;
  if (typeof value === 'string' && value.trim() !== '') {
    const n = Number(value);
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

export function numOrNull(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

// Dates as the database wants them (yyyy-mm-dd), counted back from a given day in Zambia time (UTC+2, no daylight saving).
export function lusakaDate(now: Date, daysBack = 0): string {
  const shifted = new Date(now.getTime() + 2 * 3600_000 - daysBack * 86_400_000);
  return shifted.toISOString().slice(0, 10);
}

// One CSV cell. Quotes are doubled, and a cell that starts with = + - or @ gets a leading quote mark so a
// spreadsheet never runs it as a formula (listing titles are typed by sellers).
export function csvCell(value: string | number | null | undefined): string {
  if (value === null || value === undefined) return '';
  let text = String(value);
  if (typeof value === 'string' && /^[=+\-@\t\r]/.test(text)) text = `'${text}`;
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

export function toCsv(header: string[], rows: (string | number | null | undefined)[][]): string {
  return [header, ...rows].map((r) => r.map(csvCell).join(',')).join('\r\n') + '\r\n';
}

export const GROUPS = [
  { key: 'day', label: 'Daily' },
  { key: 'week', label: 'Weekly' },
  { key: 'month', label: 'Monthly' },
] as const;
