export const DOCUMENT_TYPES = [
  { value: 'national_id', label: 'National ID' },
  { value: 'passport', label: 'Passport' },
  { value: 'drivers_licence', label: "Driver's licence" },
] as const;

export type DocumentType = (typeof DOCUMENT_TYPES)[number]['value'];

export type ReviewState = 'none' | 'pending' | 'approved' | 'rejected';

export function reviewStateLabel(state: ReviewState): string {
  if (state === 'pending') return 'Waiting for a member of our team to check it';
  if (state === 'approved') return 'Approved';
  if (state === 'rejected') return 'Not approved';
  return 'Not submitted';
}

// A business web address name: lower case letters, numbers and single dashes.
export function makeSlug(name: string): string {
  return name
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60)
    .replace(/-+$/g, '');
}

export function slugProblem(slug: string): string | null {
  return /^[a-z0-9][a-z0-9-]{1,58}[a-z0-9]$/.test(slug) ? null : 'Use at least 3 letters or numbers for the shop name.';
}

export function validateBusinessName(name: string): string | null {
  const text = name.trim();
  if (text.length < 2) return 'Enter the name of the business.';
  if (text.length > 80) return 'Keep the name under 80 characters.';
  return null;
}

export function validateRegistration(value: string): string | null {
  const text = value.trim();
  if (text.length < 3) return 'Enter the registration number from your PACRA certificate.';
  if (text.length > 40) return 'That number looks too long.';
  return null;
}

export const RATINGS = [1, 2, 3, 4, 5] as const;

export function ratingLabel(rating: number): string {
  return ['', 'Poor', 'Not good', 'Fine', 'Good', 'Excellent'][rating] ?? '';
}

export function validateReview(rating: number | null, comment: string): string | null {
  if (rating === null) return 'Choose a star rating.';
  if (comment.trim().length > 1000) return 'Keep the comment under 1000 characters.';
  return null;
}

export function validateDispute(reason: string, details: string): string | null {
  const r = reason.trim();
  if (r.length < 3) return 'Say briefly what went wrong.';
  if (r.length > 200) return 'Keep the short reason under 200 characters.';
  if (details.trim().length > 2000) return 'Keep the details under 2000 characters.';
  return null;
}

export function validateAppeal(message: string): string | null {
  const m = message.trim();
  if (m.length < 10) return 'Explain why you think the decision was wrong, in at least 10 characters.';
  if (m.length > 1500) return 'Keep it under 1500 characters.';
  return null;
}
