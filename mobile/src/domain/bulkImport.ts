// Bulk product import: reading pasted CSV (or cells copied from Excel) into rows for the server to check.
// The database checks every value again; this only turns text into rows and explains the format.

export const IMPORT_COLUMNS = [
  'sku', 'title', 'description', 'price_zmw', 'category', 'condition', 'quantity', 'low_stock_at', 'warranty_info', 'return_policy',
] as const;
export type ImportColumn = (typeof IMPORT_COLUMNS)[number];
export const REQUIRED_COLUMNS: ImportColumn[] = ['sku', 'title', 'price_zmw', 'category', 'condition', 'quantity'];
export const MAX_FILE_ROWS = 1000;

const ALIASES: Record<string, ImportColumn> = {
  sku: 'sku', 'product code': 'sku', code: 'sku',
  title: 'title', name: 'title', 'product name': 'title',
  description: 'description',
  price: 'price_zmw', price_zmw: 'price_zmw', 'price zmw': 'price_zmw', 'price (zmw)': 'price_zmw',
  category: 'category', 'category slug': 'category',
  condition: 'condition',
  quantity: 'quantity', stock: 'quantity', qty: 'quantity',
  low_stock_at: 'low_stock_at', 'low stock': 'low_stock_at', 'low stock level': 'low_stock_at',
  warranty_info: 'warranty_info', warranty: 'warranty_info',
  return_policy: 'return_policy', returns: 'return_policy',
};

export const TEMPLATE_CSV =
  'sku,title,description,price_zmw,category,condition,quantity,low_stock_at,warranty_info,return_policy\n' +
  'PH-001,Phone charger 20W,Fast charger with cable,150,electronics,new,25,5,6 months,7 days\n';

export const CONDITION_HELP = 'new, used_like_new, used_good or used_fair';

function detectDelimiter(firstLine: string): string {
  const counts = [',', '\t', ';'].map((d) => ({ d, n: firstLine.split(d).length - 1 }));
  counts.sort((a, b) => b.n - a.n);
  return counts[0] && counts[0].n > 0 ? counts[0].d : ',';
}

// Reads quoted values, doubled quotes and line breaks inside quotes.
export function parseDelimited(text: string): string[][] {
  const clean = text.replace(/^﻿/, '');
  const firstLine = clean.split(/\r?\n/, 1)[0] ?? '';
  const delim = detectDelimiter(firstLine);
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = '';
  let quoted = false;
  for (let i = 0; i < clean.length; i++) {
    const ch = clean[i]!;
    if (quoted) {
      if (ch === '"') {
        if (clean[i + 1] === '"') { cell += '"'; i++; } else quoted = false;
      } else cell += ch;
    } else if (ch === '"' && cell === '') quoted = true;
    else if (ch === delim) { row.push(cell); cell = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && clean[i + 1] === '\n') i++;
      row.push(cell); cell = '';
      rows.push(row); row = [];
    } else cell += ch;
  }
  if (cell !== '' || row.length > 0) { row.push(cell); rows.push(row); }
  return rows.filter((r) => r.some((c) => c.trim() !== ''));
}

export type ParsedImport =
  | { ok: true; rows: Record<string, string>[]; ignoredColumns: string[] }
  | { ok: false; message: string };

export function parseImportText(text: string): ParsedImport {
  const table = parseDelimited(text);
  if (table.length === 0) return { ok: false, message: 'Paste your product list first.' };
  const header = table[0]!.map((h) => h.trim().toLowerCase());
  const map: (ImportColumn | null)[] = header.map((h) => ALIASES[h] ?? null);
  const ignoredColumns = table[0]!.filter((_, i) => map[i] === null && (table[0]![i] ?? '').trim() !== '').map((h) => h.trim());
  const missing = REQUIRED_COLUMNS.filter((c) => !map.includes(c));
  if (missing.length > 0) return { ok: false, message: `Missing column${missing.length === 1 ? '' : 's'}: ${missing.join(', ')}.` };
  const body = table.slice(1);
  if (body.length === 0) return { ok: false, message: 'The list has a header but no products.' };
  if (body.length > MAX_FILE_ROWS) return { ok: false, message: `Up to ${MAX_FILE_ROWS} rows at a time. Split the list into smaller files.` };
  const rows = body.map((cells) => {
    const out: Record<string, string> = {};
    map.forEach((col, i) => {
      if (col && (cells[i] ?? '').trim() !== '') out[col] = (cells[i] ?? '').trim();
    });
    return out;
  });
  return { ok: true, rows, ignoredColumns };
}

export type ImportStatus = 'validated' | 'queued' | 'processing' | 'completed' | 'completed_with_errors' | 'failed' | 'cancelled';

export const STATUS_LABELS: Record<ImportStatus, string> = {
  validated: 'Ready to check',
  queued: 'Waiting to start',
  processing: 'Adding products',
  completed: 'Done',
  completed_with_errors: 'Done, with problems',
  failed: 'Failed',
  cancelled: 'Cancelled',
};

export const ROW_LABELS: Record<string, string> = {
  valid: 'Ready', invalid: 'Needs a fix', imported: 'Added', failed: 'Failed', skipped: 'Skipped',
};

export function canResubmit(status: ImportStatus, alreadyResent: boolean): boolean {
  return (status === 'completed_with_errors' || status === 'failed') && !alreadyResent;
}

export function isFinished(status: ImportStatus): boolean {
  return ['completed', 'completed_with_errors', 'failed', 'cancelled'].includes(status);
}
