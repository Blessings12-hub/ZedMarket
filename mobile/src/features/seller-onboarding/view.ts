// What the Seller Status screen shows, decided here so it can be tested without a phone.
// Nothing here grants anything: the database checks every action again.
import { SELLER_CLOSE, SELLER_CLOSE_REVOKED, SELLER_CLOSE_SUSPENDED, type CloseCopy } from '../../domain/closeAccount';
import { emptyForm, formOpen, showsSavedAnswers, type AppStatus, type Form } from './domain';
import type { ApplicationRequest, MyApplication } from './mine';

export type SellerScreenModel = {
  // 'approved' shows the approved-seller card; everything else shows the application (or a paused / closed state).
  mode: 'approved' | 'application';
  status: AppStatus | null;
  // True when the form can be filled in: a first application, a draft, or a fresh start after a rejected or closed one.
  editable: boolean;
  // The person has never applied. Buying never needs this, and the screen says so.
  isFirstTime: boolean;
  documentKinds: string[];
  openRequests: ApplicationRequest[];
  // Draft saved, so documents and the agreement can be added.
  showDocuments: boolean;
  // What the close-account section offers, if anything.
  close: CloseCopy | null;
  // Shown instead of the close section for a revoked seller who already closed.
  closedNote: string | null;
};

const closedByMe = (m: MyApplication) => m.history.some((h) => h.event === 'closed_by_seller');

export function closeOffer(m: MyApplication): CloseCopy | null {
  if (m.seller_status === 'active') return SELLER_CLOSE;
  if (m.seller_status === 'suspended') return SELLER_CLOSE_SUSPENDED;
  if (m.seller_status === 'revoked') return closedByMe(m) ? null : SELLER_CLOSE_REVOKED;
  return null;
}

export function buildSellerScreen(m: MyApplication): SellerScreenModel {
  const status = m.application?.status ?? null;
  const editable = formOpen(status, m.seller_status);
  return {
    mode: m.seller_status === 'active' ? 'approved' : 'application',
    status,
    editable,
    isFirstTime: m.application === null && m.seller_status === 'none',
    documentKinds: m.documents.filter((d) => d.scan !== 'infected').map((d) => d.kind),
    openRequests: m.requests.filter((r) => r.status === 'open'),
    showDocuments: m.application !== null && status === 'draft' && editable,
    close: closeOffer(m),
    closedNote: m.seller_status === 'revoked' && closedByMe(m)
      ? 'You closed your selling account. Selling stays switched off. To ask for a review, contact support.'
      : null,
  };
}

// The form as the person last saved it. A rejected or closed application starts a new, empty form.
export function formFromApplication(m: MyApplication): Form {
  const x = m.application;
  if (!x || !showsSavedAnswers(x.status)) return emptyForm();
  return {
    ...emptyForm(),
    legal_name: x.legal_name ?? '', nationality: x.nationality ?? '', is_adult: !!x.is_adult, id_type: x.id_type ?? 'nrc',
    id_number: x.id_number ?? '', residential_address: x.residential_address ?? '', selling_location_id: x.selling_location_id ?? null,
    category_ids: Array.isArray(x.category_ids) ? x.category_ids : [], sourcing_type: x.sourcing_type ?? '', sourcing_info: x.sourcing_info ?? '',
    experience_level: x.experience_level ?? '', experience_info: x.experience_info ?? '',
    expected_catalogue_size: x.expected_catalogue_size ? String(x.expected_catalogue_size) : '', returns_arrangements: x.returns_arrangements ?? '',
    customer_service_arrangements: x.customer_service_arrangements ?? '',
    declarations: x.declarations && typeof x.declarations === 'object' ? x.declarations : {},
  };
}
