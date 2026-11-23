import { supabase } from '../../lib/supabase';

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export type MyPayment = {
  id: string; ref: string; orderId: string; orderRef: string; direction: 'paid' | 'received';
  amount: number; refunded: number; method: string; status: string; failureReason: string | null;
  createdAt: string; expiresAt: string;
};

export async function paymentsEnabled(): Promise<boolean> {
  return (await rpc<boolean>('payments_enabled')) === true;
}

export async function startPayment(orderId: string, method: string, phone: string, key: string): Promise<string> {
  const row = await rpc<{ id: string }>('start_payment', { p_order_id: orderId, p_method: method, p_phone: phone, p_key: key });
  return row.id;
}

export async function cancelPayment(id: string): Promise<void> {
  await rpc('cancel_payment', { p_payment_id: id });
}

export async function fetchMyPayments(orderId: string | null = null): Promise<MyPayment[]> {
  const rows = await rpc<any[]>('my_payments', { p_order: orderId, p_limit: 50 });
  return rows.map((r) => ({
    id: r.id, ref: r.ref, orderId: r.order_id, orderRef: r.order_ref, direction: r.direction,
    amount: Number(r.amount_zmw), refunded: Number(r.refunded_zmw), method: r.method, status: r.status,
    failureReason: r.failure_reason, createdAt: r.created_at, expiresAt: r.expires_at,
  }));
}

// ---- Finance ----------------------------------------------------------------

export type FinanceRow = {
  id: string; ref: string; orderRef: string; amount: number; refunded: number; method: string; phone: string;
  status: string; needsReview: boolean; failureReason: string | null; providerRef: string | null;
  createdAt: string; openRefunds: number;
};
export type SummaryRow = { label: string; count: number; amount: number };
export type FinanceRefund = {
  id: string; paymentRef: string; amount: number; reason: string; status: string;
  requestedBy: string; decidedBy: string | null; createdAt: string;
};

export async function fetchSummary(days = 30): Promise<SummaryRow[]> {
  const rows = await rpc<any[]>('finance_summary', { p_days: days });
  return rows.map((r) => ({ label: r.label, count: r.count, amount: Number(r.amount_zmw) }));
}

export async function fetchFinancePayments(status: string | null, reviewOnly: boolean, search: string | null): Promise<FinanceRow[]> {
  const rows = await rpc<any[]>('finance_payments', {
    p_status: status, p_review_only: reviewOnly, p_search: search && search.trim() ? search.trim() : null, p_limit: 50, p_offset: 0,
  });
  return rows.map((r) => ({
    id: r.id, ref: r.ref, orderRef: r.order_ref, amount: Number(r.amount_zmw), refunded: Number(r.refunded_zmw),
    method: r.method, phone: r.payer_phone_masked, status: r.status, needsReview: r.needs_review,
    failureReason: r.failure_reason, providerRef: r.provider_ref, createdAt: r.created_at, openRefunds: r.open_refunds,
  }));
}

export async function fetchPaymentDetail(id: string): Promise<any> {
  return rpc<any>('finance_payment_detail', { p_payment: id });
}

export async function reconcilePayment(id: string, outcome: 'succeeded' | 'failed', providerRef: string, note: string): Promise<void> {
  await rpc('finance_reconcile_payment', { p_payment: id, p_outcome: outcome, p_provider_ref: providerRef || null, p_note: note });
}

export async function requestRefund(paymentId: string, amount: number, reason: string): Promise<void> {
  await rpc('finance_request_refund', { p_payment: paymentId, p_amount: amount, p_reason: reason });
}

export async function decideRefund(id: string, approve: boolean, note: string): Promise<void> {
  await rpc('finance_decide_refund', { p_refund: id, p_approve: approve, p_note: note || null });
}

export async function completeRefund(id: string, ok: boolean, providerRef: string, note: string): Promise<void> {
  await rpc('finance_complete_refund', { p_refund: id, p_ok: ok, p_provider_ref: providerRef || null, p_note: note || null });
}

export async function fetchFinanceRefunds(status: string | null): Promise<FinanceRefund[]> {
  const rows = await rpc<any[]>('finance_refunds', { p_status: status, p_limit: 50 });
  return rows.map((r) => ({
    id: r.id, paymentRef: r.payment_ref, amount: Number(r.amount_zmw), reason: r.reason, status: r.status,
    requestedBy: r.requested_by, decidedBy: r.decided_by, createdAt: r.created_at,
  }));
}
