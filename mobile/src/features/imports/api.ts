import type { ImportStatus } from '../../domain/bulkImport';
import { supabase } from '../../lib/supabase';

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export type ImportHistoryItem = {
  id: string; fileName: string; format: string; status: ImportStatus; totalRows: number;
  imported: number; failed: number; notAdded: number; resubmitOf: string | null; by: string; createdAt: string;
};
export type ImportRow = {
  id: string; rowNumber: number; status: string; data: Record<string, string>;
  errors: { field: string; message: string }[]; warnings: { field: string; message: string }[];
  listingId: string | null; failure: string | null;
};
export type ImportDetail = {
  id: string; businessId: string; fileName: string; status: ImportStatus; totalRows: number;
  resubmitOf: string | null; counts: Record<string, number>;
};

export async function createImport(businessId: string, fileName: string, format: 'csv' | 'xlsx', rows: Record<string, string>[]): Promise<string> {
  return rpc<string>('import_create_job', { p_business: businessId, p_file_name: fileName, p_format: format, p_rows: rows });
}

export async function fetchImportHistory(businessId: string): Promise<ImportHistoryItem[]> {
  const rows = await rpc<any[]>('import_history', { p_business: businessId, p_limit: 30, p_offset: 0 });
  return (rows ?? []).map((r) => ({
    id: r.id, fileName: r.file_name, format: r.source_format, status: r.status, totalRows: r.total_rows,
    imported: Number(r.imported_rows), failed: Number(r.failed_rows), notAdded: Number(r.invalid_rows),
    resubmitOf: r.resubmit_of, by: r.created_by_name, createdAt: r.created_at,
  }));
}

export async function fetchImportDetail(jobId: string): Promise<ImportDetail> {
  const d = await rpc<any>('import_job_detail', { p_job: jobId });
  return { id: d.id, businessId: d.business_id, fileName: d.file_name, status: d.status, totalRows: d.total_rows, resubmitOf: d.resubmit_of, counts: d.counts ?? {} };
}

export async function fetchImportRows(jobId: string, status: string | null): Promise<ImportRow[]> {
  const rows = await rpc<any[]>('import_rows', { p_job: jobId, p_status: status, p_limit: 200, p_offset: 0 });
  return (rows ?? []).map((r) => ({
    id: r.id, rowNumber: r.row_number, status: r.status, data: r.data ?? {}, errors: r.errors ?? [], warnings: r.warnings ?? [],
    listingId: r.listing_id, failure: r.failure,
  }));
}

export const correctImportRow = (rowId: string, data: Record<string, string>) => rpc('import_correct_row', { p_row: rowId, p_data: data });
export const submitImport = (jobId: string) => rpc('import_submit_job', { p_job: jobId });
export const cancelImport = (jobId: string) => rpc('import_cancel_job', { p_job: jobId });
export const resubmitFailed = (jobId: string) => rpc<string>('import_resubmit_failed', { p_job: jobId });
