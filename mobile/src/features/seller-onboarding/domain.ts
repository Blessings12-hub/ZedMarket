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

// Everything the person still has to do before the Send button works.
export function missingBeforeSend(f: Form, o: { agreementAccepted: boolean; documentKinds: string[]; contactVerified: boolean }): string[] {
  const out: string[] = [];
  if (!o.contactVerified) out.push('Verify your email and phone number first');
  if (f.legal_name.trim().length < 3) out.push('Your full legal name');
  if (!f.nationality.trim()) out.push('Your nationality');
  if (!f.is_adult) out.push('Confirm that you are 18 or older');
  if (!f.id_number.trim()) out.push(f.id_type === 'nrc' ? 'Your NRC number' : 'Your passport number');
  if (f.residential_address.trim().length < 8) out.push('Your residential address');
  if (f.selling_location_id == null) out.push('Where you sell from');
  if (f.category_ids.length === 0) out.push('At least one product category');
  if (!f.sourcing_type || f.sourcing_info.trim().length < 10) out.push('Where your products come from');
  if (!f.experience_level) out.push('Your selling experience');
  const n = Number(f.expected_catalogue_size);
  if (!Number.isInteger(n) || n < 1) out.push('How many products you expect to list');
  if (f.returns_arrangements.trim().length < 5) out.push('Your returns arrangements');
  if (f.customer_service_arrangements.trim().length < 5) out.push('How you will look after customers');
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
