// What the business verification screen shows, decided here so it can be tested without a phone.
import { bizFormOpen, businessStateLine, emptyBizForm, showsSavedBizAnswers, type BizForm, type Party } from './domain';
import type { BizRequest, MyBusinessApplication } from './mine';
import type { AppStatus } from '../seller-onboarding/domain';

export type BusinessScreenModel = {
  status: AppStatus | null;
  stateLine: string;
  editable: boolean;
  isFirstTime: boolean;
  documentKinds: string[];
  openRequests: BizRequest[];
  showDocuments: boolean;
  verified: boolean;
};

export function buildBusinessScreen(m: MyBusinessApplication): BusinessScreenModel {
  const status = m.application?.status ?? null;
  const editable = bizFormOpen(status, m.publish_state);
  return {
    status,
    stateLine: businessStateLine(m.publish_state, status),
    editable,
    isFirstTime: m.application === null && m.publish_state === 'none',
    documentKinds: m.documents.filter((d) => d.scan !== 'infected').map((d) => d.kind),
    openRequests: m.requests.filter((r) => r.status === 'open'),
    showDocuments: m.application !== null && status === 'draft' && editable,
    verified: m.publish_state === 'active',
  };
}

export function formFromApplication(m: MyBusinessApplication): { form: BizForm; parties: Party[] } {
  const x = m.application;
  if (!x || !showsSavedBizAnswers(x.status)) return { form: emptyBizForm(), parties: [] };
  const form: BizForm = {
    ...emptyBizForm(),
    route: x.route === 'informal_trader' ? 'informal_trader' : 'registered',
    legal_name: x.legal_name ?? '', trading_name: x.trading_name ?? '', business_type: x.business_type ?? '', pacra_number: x.pacra_number ?? '',
    pacra_registered_on: x.pacra_registered_on ?? '', tpin: x.tpin ?? '', physical_address: x.physical_address ?? '',
    selling_location_id: x.selling_location_id ?? null, phone: x.phone ?? '', email: x.email ?? '',
    category_ids: Array.isArray(x.category_ids) ? x.category_ids : [], expected_catalogue_size: x.expected_catalogue_size ? String(x.expected_catalogue_size) : '',
    trading_place: x.trading_place ?? '', years_trading: x.years_trading != null ? String(x.years_trading) : '', rep_name: x.rep_name ?? '',
    rep_role: x.rep_role ?? '', rep_is_director: x.rep_is_director !== false, rep_id_number: x.rep_id_number ?? '',
    declarations: x.declarations && typeof x.declarations === 'object' ? x.declarations : {},
  };
  return { form, parties: m.parties };
}
