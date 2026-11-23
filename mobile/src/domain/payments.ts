export type PaymentMethod = 'mtn_momo' | 'airtel_money';
export type PaymentStatus = 'pending' | 'succeeded' | 'failed' | 'cancelled';

export const METHODS: { key: PaymentMethod; label: string }[] = [
  { key: 'mtn_momo', label: 'MTN Mobile Money' },
  { key: 'airtel_money', label: 'Airtel Money' },
];

export function methodLabel(m: string): string {
  return METHODS.find((x) => x.key === m)?.label ?? m;
}

export function statusLabel(s: string, needsReview = false): string {
  if (needsReview) return 'Being checked by our team';
  switch (s) {
    case 'pending': return 'Waiting for the payment';
    case 'succeeded': return 'Paid';
    case 'failed': return 'Did not go through';
    case 'cancelled': return 'Cancelled';
    default: return s;
  }
}

// Accepts 0961234567, 260961234567, +260 96 123 4567 and returns +260961234567, or null.
export function normalisePhone(input: string): string | null {
  const digits = input.replace(/[\s()-]/g, '');
  let rest: string;
  if (/^\+260\d{9}$/.test(digits)) rest = digits.slice(4);
  else if (/^260\d{9}$/.test(digits)) rest = digits.slice(3);
  else if (/^0\d{9}$/.test(digits)) rest = digits.slice(1);
  else return null;
  return `+260${rest}`;
}

// A key made once when the pay screen opens. Sending the same key again (a double tap, a retry after a
// bad connection) gives back the same payment instead of starting a second one.
export function newPaymentKey(now: number = Date.now(), random: () => number = Math.random): string {
  return `pay-${now.toString(36)}-${Math.floor(random() * 36 ** 8).toString(36).padStart(8, '0')}`;
}

export function canStartPayment(orderStatus: string, role: 'buyer' | 'seller', payments: { status: string }[]): boolean {
  if (role !== 'buyer' || orderStatus !== 'confirmed') return false;
  return !payments.some((p) => p.status === 'pending' || p.status === 'succeeded');
}

export function refundProblem(amount: number, left: number, reason: string): string | null {
  if (!Number.isFinite(amount) || amount <= 0) return 'Enter an amount above zero.';
  if (amount > left) return `That is more than is left to refund (K${left}).`;
  if (reason.trim().length < 5) return 'Give a reason.';
  return null;
}
