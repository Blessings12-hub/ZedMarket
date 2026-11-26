// What the database tells me about my business application, checked before the app uses it.
// The database always sends every part, but the app must never trust that (the seller screen once crashed on a missing
// list). Missing lists become empty lists here. A genuinely broken answer is NOT turned into an empty success: it throws,
// so the screen shows an error and a retry.
import type { AppStatus } from '../seller-onboarding/domain';
import { STATUS_LABEL } from '../seller-onboarding/domain';
import type { Party } from './domain';

export type PublishState = 'none' | 'active' | 'suspended' | 'revoked';
export type RegistrationKind = 'registered' | 'informal_trader';
export type BizDocument = { id: string; kind: string; scan: string; review: string; note: string | null; at: string };
export type BizRequest = { id: string; message: string; document_kinds: string[]; status: string; due_at: string | null; created_at: string };
export type BizEvent = { event: string; to_status: string | null; note: string | null; at: string };
export type BizApplicationDetails = Record<string, any> & { id: string; status: AppStatus; required_documents: string[]; agreement_accepted: boolean };

export type MyBusinessApplication = {
  publish_state: PublishState;
  registration_kind: RegistrationKind | null;
  application: BizApplicationDetails | null;
  parties: (Omit<Party, 'ownership_pct'> & { ownership_pct: string })[];
  branches: { name: string; address: string; phone: string | null }[];
  permits: { permit_type: string; permit_number: string | null; issuer: string | null; expires_on: string | null }[];
  documents: BizDocument[];
  requests: BizRequest[];
  history: BizEvent[];
};

export class MalformedResponseError extends Error {
  detail: string;
  constructor(detail: string) {
    super('We could not read your business details. Please try again.');
    this.name = 'MalformedResponseError';
    this.detail = detail;
  }
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);
const str = (v: unknown, fallback = ''): string => (typeof v === 'string' ? v : fallback);
const strOrNull = (v: unknown): string | null => (typeof v === 'string' ? v : null);
const list = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const isStatus = (v: unknown): v is AppStatus => typeof v === 'string' && Object.prototype.hasOwnProperty.call(STATUS_LABEL, v);
const toPublishState = (v: unknown): PublishState => (v === 'active' || v === 'suspended' || v === 'revoked' ? v : 'none');
const toKind = (v: unknown): RegistrationKind | null => (v === 'registered' || v === 'informal_trader' ? v : null);

export function normalizeMine(raw: unknown): MyBusinessApplication {
  if (!isObject(raw)) throw new MalformedResponseError(`expected an object, got ${raw === null ? 'null' : typeof raw}`);

  let application: BizApplicationDetails | null = null;
  if (raw.application !== null && raw.application !== undefined) {
    const a = raw.application;
    if (!isObject(a) || typeof a.id !== 'string' || !isStatus(a.status)) throw new MalformedResponseError('the application has no usable id or status');
    application = {
      ...a,
      id: a.id,
      status: a.status,
      required_documents: list(a.required_documents).filter((k): k is string => typeof k === 'string'),
      agreement_accepted: a.agreement_accepted === true,
    };
  }

  return {
    publish_state: toPublishState(raw.publish_state),
    registration_kind: toKind(raw.registration_kind),
    application,
    parties: list(raw.parties).flatMap((p) =>
      isObject(p) && (p.kind === 'director' || p.kind === 'beneficial_owner') && typeof p.full_name === 'string'
        ? [{ kind: p.kind, full_name: p.full_name, nationality: str(p.nationality), ownership_pct: p.ownership_pct == null ? '' : String(p.ownership_pct), id_number: str(p.id_number) }]
        : [],
    ),
    branches: list(raw.branches).flatMap((b) => (isObject(b) && typeof b.name === 'string' ? [{ name: b.name, address: str(b.address), phone: strOrNull(b.phone) }] : [])),
    permits: list(raw.permits).flatMap((p) =>
      isObject(p) && typeof p.permit_type === 'string'
        ? [{ permit_type: p.permit_type, permit_number: strOrNull(p.permit_number), issuer: strOrNull(p.issuer), expires_on: strOrNull(p.expires_on) }]
        : [],
    ),
    documents: list(raw.documents).flatMap((d) =>
      isObject(d) && typeof d.id === 'string'
        ? [{ id: d.id, kind: str(d.kind), scan: str(d.scan, 'pending'), review: str(d.review, 'uploaded'), note: strOrNull(d.note), at: str(d.at) }]
        : [],
    ),
    requests: list(raw.requests).flatMap((r) =>
      isObject(r) && typeof r.id === 'string'
        ? [{ id: r.id, message: str(r.message), document_kinds: list(r.document_kinds).filter((k): k is string => typeof k === 'string'), status: str(r.status), due_at: strOrNull(r.due_at), created_at: str(r.created_at) }]
        : [],
    ),
    history: list(raw.history).flatMap((e) =>
      isObject(e) && typeof e.event === 'string' ? [{ event: e.event, to_status: strOrNull(e.to_status), note: strOrNull(e.note), at: str(e.at) }] : [],
    ),
  };
}

export type RpcResult = { data: unknown; error: unknown };
export type Logger = (message: string, detail?: unknown) => void;
const defaultLog: Logger = (message, detail) => console.error(message, detail);

// Runs the call, logs the real error, and rethrows it. A failed call is never turned into an empty answer.
export async function loadMine(call: () => PromiseLike<RpcResult>, log: Logger = defaultLog): Promise<MyBusinessApplication> {
  let result: RpcResult;
  try {
    result = await call();
  } catch (e) {
    log('[business] business_application_mine failed to run', e);
    throw e;
  }
  if (result.error) {
    log('[business] business_application_mine returned an error', result.error);
    throw result.error;
  }
  try {
    return normalizeMine(result.data);
  } catch (e) {
    log('[business] business_application_mine returned something unexpected', { error: e, data: result.data });
    throw e;
  }
}
