// Rules for the business application, kept apart from the screens so they can be tested without a phone.
// Nothing here grants anything: the database checks every step again.
import type { AppStatus } from '../seller-onboarding/domain';

export type Route = 'registered' | 'informal_trader';

export const BUSINESS_TYPES = [
  { key: 'limited_company', label: 'Limited company' },
  { key: 'sole_proprietorship', label: 'Sole proprietorship' },
  { key: 'partnership', label: 'Partnership' },
  { key: 'cooperative', label: 'Cooperative' },
  { key: 'ngo', label: 'NGO or association' },
];

export const BIZ_DOC_LABEL: Record<string, string> = {
  pacra_certificate: 'PACRA registration certificate',
  tpin_certificate: 'TPIN certificate',
  premises_evidence: 'Photo or proof of your premises or trading place',
  director_id: 'ID of the owner, director or trader',
  authority_letter: 'Signed letter giving you authority to act',
  ownership_evidence: 'Market association card or council trading licence',
  permit: 'Permit or licence',
  proof_of_address: 'Proof of address',
  product_evidence: 'Photos of your products',
  other: 'Other document',
};

export const requiredBusinessDocs = (route: Route, repIsDirector: boolean): string[] =>
  route === 'informal_trader'
    ? ['director_id', 'premises_evidence', 'ownership_evidence']
    : ['pacra_certificate', 'tpin_certificate', 'premises_evidence', 'director_id', ...(repIsDirector ? [] : ['authority_letter'])];

export const BIZ_DECLARATIONS = [
  { key: 'information_is_true', label: 'The information I gave is true.' },
  { key: 'authorised_to_apply', label: 'I am allowed to apply on behalf of this business.' },
  { key: 'sells_only_legal_goods', label: 'The business will only sell legal goods.' },
  { key: 'no_counterfeit_or_stolen', label: 'The business will not sell counterfeit or stolen goods.' },
  { key: 'will_honour_returns', label: 'The business will honour its returns and warranty terms.' },
];

// The database's own limits (business_applications, business_application_private, the parties tables). The app checks them
// first so a person is told which answer is wrong, and the form never accepts less than the database will.
export const LIMITS = {
  legal_name: { min: 3, max: 150 },
  trading_name: { min: 2, max: 120 },
  pacra_number: { min: 4, max: 30 },
  tpin: { min: 5, max: 20 },
  physical_address: { min: 10, max: 300 },
  trading_place: { min: 5, max: 300 },
  rep_name: { min: 3, max: 120 },
  rep_role: { min: 2, max: 80 },
  rep_id_number: { min: 5, max: 30 },
  party_name: { min: 3, max: 120 },
  expected_catalogue_size: { min: 1, max: 100000 },
  years_trading: { min: 0, max: 80 },
} as const;
export const PHONE_RE = /^\+?[0-9 ]{9,16}$/;
export const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
export const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

export function isRealDate(v: string): boolean {
  if (!DATE_RE.test(v)) return false;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}

export type Party = { kind: 'director' | 'beneficial_owner'; full_name: string; nationality: string; ownership_pct: string; id_number: string };

export type BizForm = {
  route: Route; legal_name: string; trading_name: string; business_type: string; pacra_number: string; pacra_registered_on: string; tpin: string;
  physical_address: string; selling_location_id: number | null; phone: string; email: string; category_ids: number[];
  expected_catalogue_size: string; trading_place: string; years_trading: string; rep_name: string; rep_role: string; rep_is_director: boolean;
  rep_id_number: string; declarations: Record<string, boolean>;
};

export const emptyBizForm = (): BizForm => ({
  route: 'registered', legal_name: '', trading_name: '', business_type: '', pacra_number: '', pacra_registered_on: '', tpin: '',
  physical_address: '', selling_location_id: null, phone: '', email: '', category_ids: [], expected_catalogue_size: '', trading_place: '',
  years_trading: '', rep_name: '', rep_role: '', rep_is_director: true, rep_id_number: '', declarations: {},
});

// Beneficial owners must add up to 100% (a little slack for rounding, the same as the database).
export function ownershipTotal(parties: Party[]): number {
  return parties.filter((p) => p.kind === 'beneficial_owner').reduce((n, p) => n + (Number(p.ownership_pct) || 0), 0);
}

// Problems that would make the database refuse to save even a draft. An empty answer is fine in a draft.
export function draftProblems(f: BizForm, parties: Party[] = []): string[] {
  const out: string[] = [];
  const text: [keyof typeof LIMITS, string, string][] = [
    ['legal_name', f.legal_name, 'The legal name'],
    ['trading_name', f.trading_name, 'The trading name'],
    ['pacra_number', f.pacra_number, 'The registration number'],
    ['tpin', f.tpin, 'The TPIN'],
    ['physical_address', f.physical_address, 'The physical address'],
    ['trading_place', f.trading_place, 'Where you trade'],
    ['rep_name', f.rep_name, 'The representative’s name'],
    ['rep_role', f.rep_role, 'The representative’s role'],
    ['rep_id_number', f.rep_id_number, 'The representative’s ID number'],
  ];
  for (const [key, value, label] of text) {
    const n = value.trim().length;
    const { min, max } = LIMITS[key];
    if (n > 0 && (n < min || n > max)) out.push(`${label} must be ${min} to ${max} characters.`);
  }
  if (f.phone.trim() !== '' && !PHONE_RE.test(f.phone.trim())) out.push('The phone number must be 9 to 16 digits, for example +260971000111.');
  if (f.email.trim() !== '' && !EMAIL_RE.test(f.email.trim())) out.push('The email address is not valid.');
  if (f.pacra_registered_on.trim() !== '' && !isRealDate(f.pacra_registered_on.trim())) out.push('The registration date must be a real date written as YYYY-MM-DD.');
  if (f.expected_catalogue_size.trim() !== '') {
    const n = Number(f.expected_catalogue_size);
    const { min, max } = LIMITS.expected_catalogue_size;
    if (!Number.isInteger(n) || n < min || n > max) out.push(`The number of products must be between ${min} and ${max}.`);
  }
  if (f.years_trading.trim() !== '') {
    const n = Number(f.years_trading);
    const { min, max } = LIMITS.years_trading;
    if (!Number.isInteger(n) || n < min || n > max) out.push(`Years of trading must be between ${min} and ${max}.`);
  }
  parties.forEach((p, i) => {
    const who = `Person ${i + 1}`;
    if (p.full_name.trim().length < LIMITS.party_name.min || p.full_name.trim().length > LIMITS.party_name.max) out.push(`${who}: the full name must be ${LIMITS.party_name.min} to ${LIMITS.party_name.max} characters.`);
    if (p.id_number.trim() !== '' && (p.id_number.trim().length < 5 || p.id_number.trim().length > 30)) out.push(`${who}: the ID number must be 5 to 30 characters.`);
    if (p.kind === 'beneficial_owner') {
      const n = Number(p.ownership_pct);
      if (p.ownership_pct.trim() === '' || !Number.isFinite(n) || n < 0 || n > 100) out.push(`${who}: give an ownership percentage from 0 to 100.`);
    }
  });
  return out;
}

export function missingBeforeSend(f: BizForm, parties: Party[], o: { agreementAccepted: boolean; documentKinds: string[]; contactVerified: boolean }): string[] {
  const out: string[] = [];
  if (!o.contactVerified) out.push('Verify your email and phone number first');
  const informal = f.route === 'informal_trader';
  if (f.legal_name.trim().length < LIMITS.legal_name.min) out.push(informal ? 'Your full name' : 'The legal name of the business');
  if (!informal && !f.business_type) out.push('The type of business');
  if (!informal) {
    if (f.pacra_number.trim().length < LIMITS.pacra_number.min) out.push('The PACRA registration number');
    if (!isRealDate(f.pacra_registered_on.trim())) out.push('The registration date (YYYY-MM-DD)');
    if (f.tpin.trim().length < LIMITS.tpin.min) out.push('The TPIN');
    if (!parties.some((p) => p.kind === 'director' && p.full_name.trim().length >= 3)) out.push('At least one director or proprietor');
    const total = ownershipTotal(parties);
    if (total < 99 || total > 100.01) out.push(`Beneficial owners must add up to 100% (now ${total}%)`);
  } else {
    if (f.trading_place.trim().length < LIMITS.trading_place.min) out.push('Where you trade');
    if (f.years_trading.trim() === '' || !Number.isInteger(Number(f.years_trading)) || Number(f.years_trading) < 0) out.push('How many years you have traded');
  }
  if (f.physical_address.trim().length < LIMITS.physical_address.min) out.push('The physical address');
  if (f.selling_location_id == null) out.push('The location');
  if (!PHONE_RE.test(f.phone.trim())) out.push('A phone number');
  if (!EMAIL_RE.test(f.email.trim())) out.push('An email address');
  if (f.category_ids.length === 0) out.push('At least one category');
  const n = Number(f.expected_catalogue_size);
  if (!Number.isInteger(n) || n < 1) out.push('How many products you expect to list');
  if (f.rep_name.trim().length < LIMITS.rep_name.min || f.rep_role.trim().length < LIMITS.rep_role.min) out.push('The authorised representative and their role');
  if (f.rep_id_number.trim().length < LIMITS.rep_id_number.min) out.push('The representative’s ID number');
  if (BIZ_DECLARATIONS.some((d) => !f.declarations[d.key])) out.push('Tick every declaration');
  if (!o.agreementAccepted) out.push('Accept the agreement');
  for (const k of requiredBusinessDocs(f.route, f.rep_is_director)) if (!o.documentKinds.includes(k)) out.push(`Upload: ${BIZ_DOC_LABEL[k]}`);
  return out;
}

// What the storefront may call a verified business. An informal trader is never called a registered company.
export function registrationBadge(kind: 'registered' | 'informal_trader' | null | undefined, verified: boolean): string | null {
  if (!verified) return null;
  if (kind === 'informal_trader') return 'Verified informal trader';
  return 'Verified registered business';
}

export const canEditBiz = (s: AppStatus | null): boolean => s === null || s === 'draft';
// After a rejection or a withdrawal the owner starts a fresh application (the database applies the waiting period).
export const canStartOverBiz = (s: AppStatus | null): boolean => s === 'rejected';
export const bizFormOpen = (s: AppStatus | null, publishState: string): boolean => publishState === 'none' && (canEditBiz(s) || canStartOverBiz(s));
export const showsSavedBizAnswers = (s: AppStatus | null): boolean => s !== null && !canStartOverBiz(s);

// Which fields carry a red star for this route. Anything not listed is optional (trading name, ownership summary,
// branches, permits). Used by the screen and tested, so the stars and the rules cannot drift apart.
export function requiredFields(route: Route): string[] {
  const common = ['legal_name', 'physical_address', 'selling_location_id', 'phone', 'email', 'category_ids', 'expected_catalogue_size', 'rep_name', 'rep_role', 'rep_id_number', 'declarations', 'documents', 'agreement'];
  return route === 'informal_trader'
    ? [...common, 'trading_place', 'years_trading']
    : [...common, 'business_type', 'pacra_number', 'pacra_registered_on', 'tpin', 'directors', 'beneficial_owners'];
}

// What the owner sees on the hub for this business.
export function businessStateLine(publishState: string, status: AppStatus | null): string {
  if (publishState === 'active') return 'Verified. You can publish listings.';
  if (publishState === 'suspended') return 'Publishing is suspended. Your listings and history are kept.';
  if (publishState === 'revoked') return 'Verification was withdrawn. Your history is kept.';
  if (status === 'submitted' || status === 'under_review') return 'Application sent. You cannot publish until it is approved.';
  if (status === 'additional_information_required') return 'The team needs more from you.';
  if (status === 'rejected') return 'Not approved. Read the reason and apply again after the waiting period.';
  if (status === 'draft') return 'Draft saved. You can prepare listings, but not publish.';
  return 'Not verified. You can prepare drafts, but nothing goes live until you are verified.';
}
