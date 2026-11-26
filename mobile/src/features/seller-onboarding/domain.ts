// Rules for the individual-seller application, kept apart from the screens so they can be tested without a phone.
// Nothing here grants anything: the database checks every step again. This only decides what is shown and
// catches obvious gaps before the person presses Send.

export type AppStatus =
  | 'draft' | 'submitted' | 'under_review' | 'additional_information_required'
  | 'approved' | 'rejected' | 'suspended' | 'revoked' | 'closed';

export const STATUS_LABEL: Record<AppStatus, string> = {
  draft: 'Draft',
  submitted: 'Submitted',
  under_review: 'Under review',
  additional_information_required: 'More information needed',
  approved: 'Approved',
  rejected: 'Not approved',
  suspended: 'Suspended',
  revoked: 'Revoked',
  closed: 'Closed',
};

export const STATUS_HELP: Record<AppStatus, string> = {
  draft: 'Fill in every section, then send it. You cannot sell until you are approved.',
  submitted: 'Your application is waiting for the verification team. You cannot sell until you are approved.',
  under_review: 'A member of the verification team is checking your application.',
  additional_information_required: 'The team asked for something. Answer below so the review can continue.',
  approved: 'You are approved. Your selling tools are in your Account.',
  rejected: 'This application was not approved. You can read the reason and apply again after the waiting period.',
  suspended: 'Selling is switched off. Your listings and history are kept.',
  revoked: 'Selling approval was withdrawn. Your history is kept.',
  closed: 'You deleted your selling account. To sell again, apply again: the team verifies you from the start.',
};

export const DOC_LABEL: Record<string, string> = {
  id_front: 'NRC (front)',
  id_back: 'NRC (back)',
  passport_page: 'Passport photo page',
  selfie_with_id: 'Selfie holding your ID',
  proof_of_address: 'Proof of address',
  sourcing_evidence: 'Evidence of where your stock comes from',
  product_evidence: 'Photos of your products',
  other: 'Other document',
};

export const requiredDocs = (idType: 'nrc' | 'passport'): string[] =>
  idType === 'passport' ? ['passport_page', 'selfie_with_id', 'proof_of_address'] : ['id_front', 'id_back', 'selfie_with_id', 'proof_of_address'];

export const SOURCING = [
  { key: 'own_goods', label: 'My own goods' },
  { key: 'local_purchase', label: 'Bought locally to resell' },
  { key: 'import', label: 'Imported' },
  { key: 'manufacturer', label: 'I make or supply them' },
  { key: 'other', label: 'Other' },
];
export const EXPERIENCE = [
  { key: 'none', label: 'No experience yet' },
  { key: 'under_1_year', label: 'Under a year' },
  { key: 'one_to_three_years', label: '1 to 3 years' },
  { key: 'over_three_years', label: 'Over 3 years' },
];
export const DECLARATIONS = [
  { key: 'sells_only_legal_goods', label: 'I will only sell legal goods.' },
  { key: 'no_counterfeit_or_stolen', label: 'I will not sell counterfeit or stolen goods.' },
  { key: 'information_is_true', label: 'The information I gave is true.' },
  { key: 'will_honour_returns', label: 'I will honour the returns arrangements I described.' },
];

export type Form = {
  legal_name: string; nationality: string; is_adult: boolean; id_type: 'nrc' | 'passport'; id_number: string;
  residential_address: string; selling_location_id: number | null; category_ids: number[];
  sourcing_type: string; sourcing_info: string; experience_level: string; experience_info: string;
  expected_catalogue_size: string; returns_arrangements: string; customer_service_arrangements: string;
  declarations: Record<string, boolean>;
};

export const emptyForm = (): Form => ({
  legal_name: '', nationality: '', is_adult: false, id_type: 'nrc', id_number: '', residential_address: '',
  selling_location_id: null, category_ids: [], sourcing_type: '', sourcing_info: '', experience_level: '', experience_info: '',
  expected_catalogue_size: '', returns_arrangements: '', customer_service_arrangements: '', declarations: {},
});

// The limits below are the database's own limits (seller_applications and seller_application_private). The app checks
// them first so a person is told which answer is wrong without a round trip; the database still checks again.
export const LIMITS = {
  legal_name: { min: 3, max: 120 },
  nationality: { min: 2, max: 60 },
  id_number: { min: 5, max: 30 },
  residential_address: { min: 10, max: 300 },
  sourcing_info: { min: 10, max: 1000 },
  experience_info: { min: 1, max: 1000 },
  returns_arrangements: { min: 10, max: 1000 },
  customer_service_arrangements: { min: 10, max: 1000 },
  expected_catalogue_size: { min: 1, max: 100000 },
} as const;

// Problems that would make the database refuse to even save a draft. An empty answer is fine in a draft.
export function draftProblems(f: Form): string[] {
  const out: string[] = [];
  const text: [keyof typeof LIMITS, string, string][] = [
    ['legal_name', f.legal_name, 'Your full legal name'],
    ['nationality', f.nationality, 'Your nationality'],
    ['id_number', f.id_number, 'Your ID number'],
    ['residential_address', f.residential_address, 'Your residential address'],
    ['sourcing_info', f.sourcing_info, 'What you wrote about where your products come from'],
    ['experience_info', f.experience_info, 'What you wrote about your experience'],
    ['returns_arrangements', f.returns_arrangements, 'Your returns arrangements'],
    ['customer_service_arrangements', f.customer_service_arrangements, 'How you will look after customers'],
  ];
  for (const [key, value, label] of text) {
    const n = value.trim().length;
    const { min, max } = LIMITS[key];
    if (n > 0 && (n < min || n > max)) out.push(`${label} must be ${min} to ${max} characters.`);
  }
  if (f.expected_catalogue_size.trim() !== '') {
    const n = Number(f.expected_catalogue_size);
    const { min, max } = LIMITS.expected_catalogue_size;
    if (!Number.isInteger(n) || n < min || n > max) out.push(`The number of products must be between ${min} and ${max}.`);
  }
  return out;
}

// Everything the person still has to do before the Send button works.
export function missingBeforeSend(f: Form, o: { agreementAccepted: boolean; documentKinds: string[]; contactVerified: boolean }): string[] {
  const out: string[] = [];
  const len = (v: string) => v.trim().length;
  if (!o.contactVerified) out.push('Verify your email and phone number first');
  if (len(f.legal_name) < LIMITS.legal_name.min) out.push('Your full legal name');
  if (len(f.nationality) < LIMITS.nationality.min) out.push('Your nationality');
  if (!f.is_adult) out.push('Confirm that you are 18 or older');
  if (len(f.id_number) < LIMITS.id_number.min) out.push(f.id_type === 'nrc' ? 'Your NRC number' : 'Your passport number');
  if (len(f.residential_address) < LIMITS.residential_address.min) out.push('Your residential address');
  if (f.selling_location_id == null) out.push('Where you sell from');
  if (f.category_ids.length === 0) out.push('At least one product category');
  if (!f.sourcing_type || len(f.sourcing_info) < LIMITS.sourcing_info.min) out.push('Where your products come from');
  if (!f.experience_level) out.push('Your selling experience');
  const n = Number(f.expected_catalogue_size);
  if (!Number.isInteger(n) || n < LIMITS.expected_catalogue_size.min) out.push('How many products you expect to list');
  if (len(f.returns_arrangements) < LIMITS.returns_arrangements.min) out.push('Your returns arrangements');
  if (len(f.customer_service_arrangements) < LIMITS.customer_service_arrangements.min) out.push('How you will look after customers');
  if (DECLARATIONS.some((d) => !f.declarations[d.key])) out.push('Tick every declaration');
  if (!o.agreementAccepted) out.push('Accept the seller agreement');
  for (const k of requiredDocs(f.id_type)) if (!o.documentKinds.includes(k)) out.push(`Upload: ${DOC_LABEL[k]}`);
  return out;
}

export const canEdit = (s: AppStatus | null): boolean => s === null || s === 'draft';
export const isFinished = (s: AppStatus): boolean => s === 'rejected' || s === 'revoked' || s === 'closed';

// A rejected, withdrawn or deleted application is over. The person may start a new one (a rejected one only after the
// waiting period, which the database enforces). The new application starts empty: nothing is carried over.
export const canStartOver = (s: AppStatus | null): boolean => s === 'rejected' || s === 'closed';
export const formOpen = (s: AppStatus | null, sellerStatus: string): boolean => sellerStatus === 'none' && (canEdit(s) || canStartOver(s));
export const showsSavedAnswers = (s: AppStatus | null): boolean => s !== null && !canStartOver(s);

// What a reviewer may do from the detail screen. The database refuses the rest (own application, no claim, second approver).
export type Action = 'claim' | 'request_info' | 'interview' | 'escalate' | 'approve' | 'reject' | 'suspend' | 'reinstate';
export function staffActions(s: AppStatus, o: { mine: boolean; assigned: boolean }): Action[] {
  if (s === 'submitted') return ['claim'];
  if (s === 'under_review') {
    if (!o.mine) return o.assigned ? [] : ['claim'];
    return ['request_info', 'interview', 'escalate', 'approve', 'reject'];
  }
  if (s === 'additional_information_required') return o.mine ? ['escalate'] : [];
  if (s === 'approved') return ['suspend'];
  if (s === 'suspended') return ['reinstate'];
  return [];
}

export const QUEUES = [
  { key: 'sellers', label: 'Seller applications' },
  { key: 'documents', label: 'Pending documents' },
  { key: 'info_requested', label: 'Information requested' },
  { key: 'escalated', label: 'Escalated' },
  { key: 'approved', label: 'Approved' },
  { key: 'rejected', label: 'Rejected' },
  { key: 'suspended', label: 'Suspended / revoked' },
] as const;
export type QueueKey = (typeof QUEUES)[number]['key'];

export const RISK_LABEL = (r: string) => (r === 'high' ? 'Higher risk: interview and two officers' : 'Standard');
