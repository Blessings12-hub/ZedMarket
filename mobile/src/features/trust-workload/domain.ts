// Normalises the workload answer so a missing or odd field never crashes the dashboard.
export type Counts = { submitted: number; under_review: number; info_requested: number; escalated: number; overdue: number; awaiting_second: number; unassigned: number };
export type Workload = {
  escalationDueHours: number; mine: number; escalationsOverdue: number;
  seller: Counts; business: Counts; officers: { id: string; name: string; open: number }[];
};
export type AccessRow = { officerId: string; name: string; documentOpens: number; privateViews: number; people: number; lastAt: string | null; flagged: boolean };

const n = (v: unknown): number => { const x = Number(v); return Number.isFinite(x) ? x : 0; };
export function normalizeCounts(v: any): Counts {
  const o = v && typeof v === 'object' ? v : {};
  return { submitted: n(o.submitted), under_review: n(o.under_review), info_requested: n(o.info_requested), escalated: n(o.escalated),
           overdue: n(o.overdue), awaiting_second: n(o.awaiting_second), unassigned: n(o.unassigned) };
}
export function normalizeWorkload(v: any): Workload {
  if (!v || typeof v !== 'object') throw new Error('The workload came back empty.');
  return {
    escalationDueHours: n(v.escalation_due_hours) || 24, mine: n(v.mine), escalationsOverdue: n(v.escalations_overdue),
    seller: normalizeCounts(v.kinds?.seller), business: normalizeCounts(v.kinds?.business),
    officers: Array.isArray(v.officers) ? v.officers.map((o: any) => ({ id: String(o.id), name: String(o.name ?? 'Unknown'), open: n(o.open) })) : [],
  };
}
export function normalizeAccess(rows: any): AccessRow[] {
  if (!Array.isArray(rows)) return [];
  return rows.map((r) => ({ officerId: String(r.officer_id), name: String(r.officer_name ?? 'Unknown'), documentOpens: n(r.document_opens),
    privateViews: n(r.private_views), people: n(r.people_touched), lastAt: r.last_at ?? null, flagged: !!r.flagged }));
}
export const needsAttention = (c: Counts): number => c.overdue + c.escalated + c.awaiting_second;
