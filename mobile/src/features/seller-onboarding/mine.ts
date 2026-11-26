// What the database tells me about my own seller application, checked before the app uses it.
// The database now always sends five parts (seller_status, application, documents, requests, history), but the app must
// never trust that: a missing list used to crash the Seller Status screen. Missing lists become empty lists here.
// A genuinely broken answer is NOT turned into an empty success: it throws, so the screen shows an error and a retry.
import { toSellerStatus, type SellerStatus } from '../../domain/sellerAccess';
import { STATUS_LABEL, type AppStatus } from './domain';

export type ApplicationDocument = { id: string; kind: string; scan: string; review: string; note: string | null; at: string };
export type ApplicationRequest = { id: string; message: string; document_kinds: string[]; status: string; due_at: string | null; created_at: string };
export type ApplicationEvent = { event: string; to_status: string | null; note: string | null; at: string };
export type ApplicationDetails = Record<string, any> & {
  id: string;
  status: AppStatus;
  required_documents: string[];
  agreement_accepted: boolean;
};

export type MyApplication = {
  seller_status: SellerStatus;
  application: ApplicationDetails | null;
  documents: ApplicationDocument[];
  requests: ApplicationRequest[];
  history: ApplicationEvent[];
};

export class MalformedResponseError extends Error {
  constructor(detail: string) {
    super('We could not read your seller status. Please try again.');
    this.name = 'MalformedResponseError';
    this.detail = detail;
  }
  detail: string;
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);
const str = (v: unknown, fallback = ''): string => (typeof v === 'string' ? v : fallback);
const strOrNull = (v: unknown): string | null => (typeof v === 'string' ? v : null);
const list = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const isStatus = (v: unknown): v is AppStatus => typeof v === 'string' && Object.prototype.hasOwnProperty.call(STATUS_LABEL, v);

export function normalizeMine(raw: unknown): MyApplication {
  if (!isObject(raw)) throw new MalformedResponseError(`expected an object, got ${raw === null ? 'null' : typeof raw}`);

  let application: ApplicationDetails | null = null;
  if (raw.application !== null && raw.application !== undefined) {
    const a = raw.application;
    if (!isObject(a) || typeof a.id !== 'string' || !isStatus(a.status)) {
      throw new MalformedResponseError('the application has no usable id or status');
    }
    application = {
      ...a,
      id: a.id,
      status: a.status,
      required_documents: list(a.required_documents).filter((k): k is string => typeof k === 'string'),
      agreement_accepted: a.agreement_accepted === true,
    };
  }

  return {
    seller_status: toSellerStatus(raw.seller_status),
    application,
    documents: list(raw.documents).flatMap((d) =>
      isObject(d) && typeof d.id === 'string'
        ? [{ id: d.id, kind: str(d.kind), scan: str(d.scan, 'pending'), review: str(d.review, 'uploaded'), note: strOrNull(d.note), at: str(d.at) }]
        : [],
    ),
    requests: list(raw.requests).flatMap((r) =>
      isObject(r) && typeof r.id === 'string'
        ? [{
            id: r.id,
            message: str(r.message),
            document_kinds: list(r.document_kinds).filter((k): k is string => typeof k === 'string'),
            status: str(r.status),
            due_at: strOrNull(r.due_at),
            created_at: str(r.created_at),
          }]
        : [],
    ),
    history: list(raw.history).flatMap((e) =>
      isObject(e) && typeof e.event === 'string'
        ? [{ event: e.event, to_status: strOrNull(e.to_status), note: strOrNull(e.note), at: str(e.at) }]
        : [],
    ),
  };
}

export type RpcResult = { data: unknown; error: unknown };
export type Logger = (message: string, detail?: unknown) => void;
const defaultLog: Logger = (message, detail) => console.error(message, detail);

// Runs the call, logs the real error, and rethrows it. A failed call is never turned into an empty answer.
export async function loadMine(call: () => PromiseLike<RpcResult>, log: Logger = defaultLog): Promise<MyApplication> {
  let result: RpcResult;
  try {
    result = await call();
  } catch (e) {
    log('[seller] seller_application_mine failed to run', e);
    throw e;
  }
  if (result.error) {
    log('[seller] seller_application_mine returned an error', result.error);
    throw result.error;
  }
  try {
    return normalizeMine(result.data);
  } catch (e) {
    log('[seller] seller_application_mine returned something unexpected', { error: e, data: result.data });
    throw e;
  }
}
